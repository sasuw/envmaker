package Dotfiletracker::TargetGuard;
use strict;
use warnings;
use Cwd qw(abs_path);
use Encode qw(encode decode FB_CROAK);
use Fcntl qw(:DEFAULT :flock :mode F_GETFD F_SETFD FD_CLOEXEC);
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempfile);
use IO::Handle;
use JSON::PP;
use POSIX ();

sub fail { die "dotfiletracker: $_[0]\n"; }
sub bytes { return encode('UTF-8', $_[0]); }
sub text { my $copy = $_[0]; return decode('UTF-8', $copy, FB_CROAK); }
sub json { return JSON::PP->new->utf8->canonical; }
sub read_json {
    my ($file) = @_;
    return undef unless -e $file || -l $file;
    my $parent = dirname($file);
    -d $parent && abs_path($parent) eq $parent or fail("Redirected state ancestor: $parent");
    -f $file && !-l $file or fail("Unsafe state file: $file");
    open my $fh, '<', $file or fail("Cannot read $file: $!");
    local $/;
    my $data = <$fh>;
    close $fh;
    my $value = eval { json()->decode($data) };
    !$@ && ref($value) eq 'HASH' or fail("Invalid state JSON: $file");
    return $value;
}
sub canonical_future {
    my ($path) = @_;
    $path = File::Spec->rel2abs($path);
    my @tail;
    while (!-e $path && !-l $path) {
        unshift @tail, File::Basename::basename($path);
        my $parent = dirname($path);
        $parent ne $path or fail('Cannot resolve state path');
        $path = $parent;
    }
    my $base = abs_path($path);
    defined $base && -d $base or fail("Invalid state ancestor: $path");
    for my $part (@tail) {
        next if $part eq '.';
        if ($part eq '..') { $base = dirname($base); }
        else { $base .= "/$part"; }
    }
    return $base;
}
sub state_path {
    return canonical_future(($ENV{XDG_STATE_HOME} || "$ENV{HOME}/.local/state") . '/dotfiletracker');
}
sub for_entry {
    my ($class, %args) = @_;
    # Every command entry uses this policy. A nested command must validate its
    # inherited open description instead of independently acquiring the lock.
    return $class->new(%args, inherit => defined $ENV{DFT_GUARD_FD});
}
sub _ownership {
    my ($self, $mode) = @_;
    my $record = $self->{record};
    return unless $record->{owner_state};
    my $owner = bytes($record->{owner_state});
    -d $owner && !-l $owner && canonical_future($owner) eq $owner
        or fail("Recorded stack state is unavailable or redirected: $owner");
    my @owner_stat = stat $owner;
    $owner_stat[4] == $< && !($owner_stat[2] & 0077)
        or fail('Recorded stack state is not private to its owner (0700 required)');
    my $pending = read_json("$owner/pending.json");
    if (!$pending && $record->{intent}) {
        $record->{intent} =~ /^[a-f0-9]{32}$/ or fail('Invalid ownership intent identity');
        my $operation = "$owner/operations/$record->{intent}";
        $pending = read_json("$operation/completed.json") || read_json("$operation/intent.json")
            or fail('Recorded operation intent is unavailable');
    }
    my $applied = read_json("$owner/applied.json");
    if ($applied) {
        exists $applied->{generation} && ($applied->{target_root} || '') eq text($self->{home}) &&
            ($applied->{state_dir} || '') eq text($owner) or fail('Invalid applied ownership receipt');
    }
    my $active = $record->{protected} || $pending || ($applied && $applied->{generation});
    !$record->{protected} || $applied || $pending or fail('Protected target has lost ownership evidence; refusing fresh adoption');
    if ($mode =~ /^legacy/) {
        !$active or fail("Stack owns this target; use recovery/stack commands with state $owner");
    } else {
        (!$active || $owner eq $self->{state}) or fail("Target is owned by a different stack state: $owner");
        (!$pending || $mode eq 'recovery' || $mode eq 'inspect') or fail("Unfinished stack operation; run recover inspect with state $owner");
    }
}
sub new {
    my ($class, %args) = @_;
    my $home = abs_path($ENV{HOME});
    defined $home && -d $home or fail('HOME must resolve to an existing directory');
    my $self = bless { home => $home, state => state_path(), path => "$home/.dotfiletracker-lock",
        owner_path => "$home/.dotfiletracker-owner.json" }, $class;
    my $mode = $args{mode} || 'stack';
    my $readonly = $mode eq 'legacy-preview' || $mode eq 'inspect';
    if ($args{inherit}) {
        my $fd = $ENV{DFT_GUARD_FD};
        defined $fd && $fd =~ /^\d+$/ or fail('Missing inherited target lock');
        open $self->{fh}, '+<&', $fd or fail('Invalid inherited target lock descriptor');
        $self->{inherited_fd} = $fd;
    } else {
        if ((!-e $self->{path} && !-l $self->{path}) && (-e $self->{owner_path} || -l $self->{owner_path})) {
            fail('Target lock is missing while its ownership record remains; restore the reserved lock inode');
        }
        if ($readonly && !-e $self->{path} && !-l $self->{path}) {
            $self->{record} = {};
            return $self;
        }
        my $flags = $readonly ? O_RDONLY : O_RDWR | O_CREAT;
        if (-e $self->{path} || -l $self->{path}) {
            my @named = lstat $self->{path};
            S_ISREG($named[2]) or fail('Target lock must be a regular file, not a symlink or special entry');
        }
        sysopen($self->{fh}, $self->{path}, $flags | O_NOFOLLOW | O_NONBLOCK, 0600)
            or fail("Cannot open target lock $self->{path}: $!");
    }
    my @actual = stat $self->{fh};
    my @named = lstat $self->{path};
    @named && S_ISREG($named[2]) && !($named[2] & 0022) && $named[3] == 1 && $named[4] == $< &&
        $named[0] == $actual[0] && $named[1] == $actual[1]
        or fail('Target lock is a symlink, foreign file, or changed inode');
    # An inherited writer descriptor shares its open-file description with the
    # parent. Verification must never downgrade that parent's exclusive flock.
    flock($self->{fh}, ($readonly && !$args{inherit} ? LOCK_SH : LOCK_EX) | LOCK_NB)
        or fail("Target lock is held by another operation: $self->{path}; a background process may have inherited an open lock descriptor");
    # Verified duplicates and newly opened handles stay private by default.
    my $flags = fcntl($self->{fh}, F_GETFD, 0);
    defined $flags && fcntl($self->{fh}, F_SETFD, $flags | FD_CLOEXEC)
        or fail('Cannot protect target lock descriptor');
    $self->{record} = read_json($self->{owner_path}) || {};
    if ($self->{record}{target}) {
        $self->{record}{target} eq text($home) or fail('Target lock belongs to another home');
    }
    $self->_ownership($mode);
    if (!$readonly && !$args{inherit}) {
        $self->{record}{target} = text($home);
        $self->{record}{holder} = { pid => $$, started => time, mode => $mode };
        $self->_save;
    }
    return $self;
}
sub _save {
    my ($self) = @_;
    !-l $self->{owner_path} or fail('Ownership record is a symlink');
    my ($fh, $temporary) = tempfile('.dotfiletracker-owner.XXXXXX', DIR => $self->{home}, UNLINK => 0);
    print {$fh} json()->encode($self->{record}), "\n" or fail('Cannot write target ownership record');
    $fh->flush && $fh->sync or fail('Cannot sync target ownership record');
    close $fh or fail('Cannot close target ownership record');
    rename $temporary, $self->{owner_path} or fail('Cannot publish target ownership record');
}
sub claim {
    my ($self, $intent) = @_;
    $self->{record}{owner_state} = text($self->{state});
    $self->{record}{protected} = 1;
    $self->{record}{intent} = $intent;
    $self->_save;
}
sub published {
    my ($self, $generation) = @_;
    $self->{record}{protected} = $generation ? 1 : 0;
    $self->{record}{intent} = undef;
    $self->_save;
}
sub inherited_fd {
    my ($self) = @_;
    # Call only in the intended internal child, after fork. Never change the
    # parent's flags just to launch Stow or a nested guarded command.
    # Forward one verified handle, not an accumulating chain of originals.
    # This is child-local for the same reason as clearing CLOEXEC below.
    if (defined $self->{inherited_fd} && $self->{inherited_fd} != fileno($self->{fh})) {
        POSIX::close(delete $self->{inherited_fd}) == 0 or fail('Cannot close original target lock handoff');
    }
    my $flags = fcntl($self->{fh}, F_GETFD, 0);
    defined $flags && fcntl($self->{fh}, F_SETFD, $flags & ~FD_CLOEXEC)
        or fail('Cannot inherit target lock');
    return fileno($self->{fh});
}
sub exec_external {
    my ($self, @command) = @_;
    # Perl stack hooks use this boundary; shell discovery/hooks close their
    # handoff in dft_run_external so Bash keeps command lookup and ENOEXEC.
    # Close both the verified duplicate and the original internal handoff, if
    # present. Never LOCK_UN: these copies share the parent's open description.
    my $fd = delete $ENV{DFT_GUARD_FD};
    my $own_fd = ref($self) && $self->{fh} ? fileno($self->{fh}) : undef;
    if (defined $own_fd) {
        close $self->{fh} or fail('Cannot close external target lock copy');
        delete $self->{fh};
    }
    if (defined $fd && (!defined $own_fd || $fd ne $own_fd)) {
        $fd =~ /^\d+$/ && POSIX::close($fd) == 0
            or fail('Cannot close inherited external target lock copy');
    }
    exec { $command[0] } @command;
    warn "Cannot execute external command: $!\n";
    POSIX::_exit(127);
}
sub finish {
    my ($self) = @_;
    return unless $self->{fh};
    # A guarded descendant may have published a generation. Preserve that
    # descendant's ownership update instead of writing the parent's old copy.
    $self->{record} = read_json($self->{owner_path}) or fail('Target ownership record disappeared while locked');
    ($self->{record}{target} || '') eq text($self->{home}) or fail('Target ownership record changed while locked');
    $self->{record}{holder} = undef;
    $self->_save;
    # No LOCK_UN: inherited descriptors share the flock. Kernel close/release
    # keeps the target locked until every actual mutator has exited.
    close $self->{fh};
    delete $self->{fh};
}
1;
