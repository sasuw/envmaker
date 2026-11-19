package Dotfiletracker::OverlayState;
use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:DEFAULT :mode);
use File::Basename qw(dirname basename);
use File::Spec;
use File::Temp qw(tempfile);
use IO::Handle;
use POSIX ();
use Dotfiletracker::TargetGuard;

sub fail { Dotfiletracker::TargetGuard::fail($_[0]); }
sub b { Dotfiletracker::TargetGuard::bytes($_[0]); }
sub u { Dotfiletracker::TargetGuard::text($_[0]); }
sub json { Dotfiletracker::TargetGuard::json(); }
sub read_json { Dotfiletracker::TargetGuard::read_json($_[0]); }
sub exists_entry { return -e $_[0] || -l $_[0]; }
sub within { return $_[0] eq $_[1] || index($_[0], "$_[1]/") == 0; }
sub normalized {
    my ($target) = @_;
    defined $target && length($target) && $target !~ m{\A/|(?:\A|/)\.{1,2}(?:/|\z)|//|/\z|\0}
        or fail('Invalid target in generation manifest');
    return b($target);
}
sub secure_directory {
    my ($directory) = @_;
    my $cursor = '/';
    for my $part (grep { length } split m{/}, $directory) {
        $cursor = $cursor eq '/' ? "/$part" : "$cursor/$part";
        if (!exists_entry($cursor)) { mkdir($cursor, 0700) or fail("Cannot create state directory $cursor: $!"); }
        -d $cursor && !-l $cursor or fail("Unsafe directory ancestor: $cursor");
    }
}
sub write_json {
    my ($file, $value) = @_;
    !-l $file or fail("State file is a symlink: $file");
    my ($fh, $temporary) = tempfile('.atomic.XXXXXX', DIR => dirname($file), UNLINK => 0);
    print {$fh} json()->encode($value), "\n" or fail("Cannot write $temporary");
    $fh->flush && $fh->sync or fail("Cannot sync $temporary");
    close $fh or fail("Cannot close $temporary");
    rename($temporary, $file) or fail("Cannot publish $file: $!");
}
sub identifier {
    open my $random, '<', '/dev/urandom' or fail('Cannot open random identifier source');
    read($random, my $bytes, 16) == 16 or fail('Cannot read random identifier');
    close $random;
    return unpack('H*', $bytes);
}
sub new {
    my ($class, %args) = @_;
    my $mode = $args{mode} || 'stack';
    $mode =~ /^(?:stack|inspect|recovery)$/ or fail('Invalid lifecycle guard role');
    my $self = bless { mode => $mode, runtime => $args{runtime}, source_roots => $args{source_roots}, verbose => $args{verbose},
        inject => $args{inject} || sub {} }, $class;
    return $self;
}
sub _begin {
    my ($self, $role, $require_sources) = @_;
    $self->{mode} eq $role || ($role eq 'inspect' && $self->{mode} eq 'recovery')
        or fail('Lifecycle operation cannot use a read-only or different guard role');
    if ($self->{guard} && $self->{guard}{fh}) {
        $self->{guard}->_ownership($self->{mode});
        return;
    }
    if ($require_sources) {
        ref($self->{source_roots}) eq 'ARRAY' && @{$self->{source_roots}}
            or fail('Apply requires its registered source roots before lock creation');
        my $home = abs_path($ENV{HOME}) or fail('Missing target home');
        for my $source (@{$self->{source_roots}}) {
            my $root = abs_path($source);
            defined $root && -d $root or fail('Registered source disappeared before target lock');
            within($home, $root) and fail('Home target/lock namespace overlaps a registered source');
        }
    }
    my $guard = Dotfiletracker::TargetGuard->for_entry(mode => $self->{mode});
    @{$self}{qw(guard home state)} = ($guard, $guard->{home}, $guard->{state});
}
sub _prepare_state {
    my ($self) = @_;
    secure_directory($self->{state});
    my @stat = stat $self->{state};
    $stat[4] == $< && !($stat[2] & 0077) or fail('Stack state directory must be private to its owner (0700)');
    for my $child (qw(stow manifests operations)) { secure_directory("$self->{state}/$child"); }
}
sub _point { my ($self, $phase) = @_; $self->{inject}->($phase, $self); }
sub _journal {
    my ($self, $phase) = @_;
    $self->{pending}{phase} = $phase if defined $phase;
    if (defined $phase && $phase =~ /^(?:built|simulated|stow-complete|verified|published)$/) {
        $self->{pending}{last_completed} = $phase;
    }
    write_json("$self->{state}/pending.json", $self->{pending});
}
sub _receipt {
    my ($self, $generation, $manifest) = @_;
    return { generation => $generation, target_root => u($self->{home}), state_dir => u($self->{state}),
        manifest_sha256 => $manifest ? sha256_hex(json()->encode($manifest)) : undef,
        ancestors => {}, links => {} };
}
sub _manifest {
    my ($self, $receipt) = @_;
    return { targets => [], sources => [] } unless $receipt && $receipt->{generation};
    my $id = $receipt->{generation};
    $id =~ /^generation_[a-f0-9]{32}$/ or fail('Invalid generation identity');
    $receipt->{target_root} eq u($self->{home}) && $receipt->{state_dir} eq u($self->{state})
        or fail('Generation receipt belongs to another target/state');
    my $manifest = read_json("$self->{state}/manifests/$id.json") or fail('Missing retained generation manifest');
    sha256_hex(json()->encode($manifest)) eq $receipt->{manifest_sha256} or fail('Retained generation manifest changed');
    $manifest->{generation} eq $id or fail('Manifest generation mismatch');
    return $manifest;
}
sub _stow_link_text {
    my ($self, $stow_directory, $package, $target) = @_;
    # Stow::stow_node prefixes the package path relative to HOME with one
    # ../ per target-parent level. Do not shorten shared prefixes below HOME:
    # .local/bin needs ../../.local/state/..., not ../state/.... Inputs are
    # canonical directory paths and normalized package-relative byte strings.
    my $depth = $target =~ tr{/}{/};
    return File::Spec->canonpath(('../' x $depth) . File::Spec->abs2rel($stow_directory, $self->{home}) . "/$package/$target");
}
sub _home_text {
    my ($self, $receipt, $target) = @_;
    my $calculated = $self->_stow_link_text("$self->{state}/stow", $receipt->{generation}, $target);
    # Releases before the Stow-text fix journaled shortest paths. Accept that
    # specific receipt encoding for recovery, but require the actual HOME link
    # to have Stow's literal text. A dereference-equivalent replacement is not
    # ownership. Successful verification upgrades the published receipt.
    my $previous_encoding = File::Spec->abs2rel("$self->{state}/stow/$receipt->{generation}/$target", dirname("$self->{home}/$target"));
    defined $receipt->{links}{u($target)} &&
        (b($receipt->{links}{u($target)}) eq $calculated || b($receipt->{links}{u($target)}) eq $previous_encoding)
        or fail('Recorded home link text/generation location mismatch');
    return $calculated;
}
sub _parents {
    my ($self, $target, $expected) = @_;
    my %found;
    my $relative = '';
    my @parts = split m{/}, $target;
    pop @parts;
    for my $part ('', @parts) {
        $relative .= (length($relative) ? '/' : '') . $part if length($part);
        my $path = length($relative) ? "$self->{home}/$relative" : $self->{home};
        next unless exists_entry($path);
        # Migration is the only operation allowed to unfold a recorded legacy
        # directory link. Never inspect children through that link in HOME.
        my $legacy = $self->{migration} ? $self->{migration}{links}{u($relative)} : undef;
        if ($legacy && $legacy->{folded} && -l $path && readlink($path) eq b($legacy->{text})) {
            last;
        }
        my @stat = lstat $path;
        S_ISDIR($stat[2]) or fail("Target ancestor is not a real directory: $path");
        my $identity = "$stat[0]:$stat[1]";
        if ($expected && exists $expected->{u($relative)}) {
            $expected->{u($relative)} eq $identity or fail("Managed target ancestor was replaced: $path");
        }
        $found{u($relative)} = $identity;
    }
    return \%found;
}
sub _generation_entries {
    my ($self, $receipt, $manifest) = @_;
    return unless $receipt && $receipt->{generation};
    my $directory = "$self->{state}/stow/$receipt->{generation}";
    -d $directory && !-l $directory && abs_path($directory) eq $directory or fail('Generation directory changed');
    my %expected = ('.stow-local-ignore' => 'metadata');
    for my $entry (@{$manifest->{targets}}) {
        my $target = normalized($entry->{target});
        my $path = "$directory/$target";
        $expected{$target} = 'link';
        my $ancestor = dirname($target);
        while ($ancestor ne '.') { $expected{$ancestor} = 'directory'; $ancestor = dirname($ancestor); }
        my $parent = dirname($path);
        abs_path($parent) && abs_path($parent) eq $parent or fail('Generated ancestor was redirected');
        -l $path && readlink($path) eq File::Spec->abs2rel(b($entry->{owner}{source_entry}), $parent)
            or fail("Generated source link was replaced: $path");
    }
    my $scan;
    $scan = sub {
        my ($relative) = @_;
        my $path = length($relative) ? "$directory/$relative" : $directory;
        opendir my $dh, $path or fail('Cannot verify generation directory');
        my @names = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        for my $name (@names) {
            my $child = length($relative) ? "$relative/$name" : $name;
            my $type = $expected{$child} or fail("Unrecorded generated entry: $child");
            my $full = "$directory/$child";
            if ($type eq 'directory') { -d $full && !-l $full or fail('Generated directory replaced'); $scan->($child); }
            elsif ($type eq 'metadata') {
                -f $full && !-l $full or fail('Generated ignore policy replaced');
                open my $fh, '<', $full or fail('Cannot read generated ignore policy');
                my $bytes = do { local $/; <$fh> }; close $fh;
                $bytes eq "# Frozen overlay selection; do not apply default ignores again.\n" or fail('Generated ignore policy changed');
            }
        }
    };
    $scan->(''); undef $scan;
}
sub _check_targets {
    my ($self, $old, $new, $old_manifest, $new_manifest, $recovery) = @_;
    my (%old_entries, %new_entries, %parents);
    for my $entry (@{$old_manifest->{targets}}) { $old_entries{$entry->{target}} = $entry; }
    for my $entry (@{$new_manifest->{targets}}) { $new_entries{$entry->{target}} = $entry; }
    for my $name (sort keys %{{ %old_entries, %new_entries }}) {
        my $target = normalized($name);
        my %expected = (%{$old->{ancestors} || {}}, %{$self->{pending}{parents_before} || {}});
        my $found = $self->_parents($target, \%expected);
        @parents{keys %$found} = values %$found;
        my $path = "$self->{home}/$target";
        $target !~ /^\.dotfiletracker-/ or fail('Target uses reserved lock/ownership namespace');
        my @protected = ($self->{state}, "$self->{home}/.dotfiletracker-lock", "$self->{home}/.dotfiletracker-owner.json",
            Dotfiletracker::TargetGuard::canonical_future(($ENV{XDG_CONFIG_HOME} || "$ENV{HOME}/.config") . '/dotfiletracker'));
        push @protected, map { b($_->{root}) } @{$new_manifest->{sources} || []};
        push @protected, map { b($_->{root}) } @{$old_manifest->{sources} || []};
        for my $protected (@protected) {
            (within($path, $protected) || within($protected, $path)) and fail("Target overlaps a source/control path: $path");
        }
        next unless exists_entry($path);
        if ($self->{migration}) {
            my $legacy = $self->{migration}{links}{$name};
            next if $legacy && -l $path && readlink($path) eq b($legacy->{text});
            my $folded = $self->_legacy_fold($target);
            next if $folded;
        }
        my $owned_old = $old_entries{$name} && $old->{generation} && -l $path && readlink($path) eq $self->_home_text($old, $target);
        my $owned_new = $recovery && $new_entries{$name} && $new->{generation} && -l $path && readlink($path) eq $self->_home_text($new, $target);
        ($owned_old || $owned_new) or fail("Target conflict; preserving replacement: $path");
    }
    return \%parents;
}
sub _validate_sources {
    my ($self, $plan, $check_policy) = @_;
    $check_policy = 1 unless defined $check_policy;
    for my $source (@{$plan->{sources}}) {
        my $root = b($source->{root});
        -d $root && abs_path($root) eq $root or fail("Source unavailable or redirected: $root");
        (within($self->{state}, $root) || within($root, $self->{state})) and fail('Source overlaps generated state');
    }
    for my $entry (@{$plan->{targets}}) {
        my ($source) = grep { $_->{id} eq $entry->{owner}{source_id} } @{$plan->{sources}};
        $source or fail('Winner has no registered source');
        my $path = b($entry->{owner}{source_entry});
        within($path, b($source->{root})) && $path ne b($source->{root}) or fail('Winner escaped its source');
        abs_path(dirname($path)) && abs_path(dirname($path)) eq dirname($path) or fail('Source ancestor was redirected');
        my @stat = lstat $path;
        @stat or fail("Source entry disappeared: $path");
        my $type = S_ISREG($stat[2]) ? 'file' : S_ISLNK($stat[2]) ? 'symlink' : 'unsupported';
        $type eq $entry->{owner}{entry_type} && S_IMODE($stat[2]) == $entry->{owner}{mode}
            or fail("Source entry type/mode changed: $path");
        if ($type eq 'symlink') {
            -f $path && readlink($path) eq b($entry->{owner}{link_text}) or fail("Source link changed: $path");
        }
    }
    return unless $check_policy;
    for my $policy ((map { $_->{ignore_policy} } @{$plan->{packages} || []}), @{$plan->{resource_files} || []}) {
        next unless $policy->{file};
        my $file = b($policy->{file});
        -f $file or fail("Filtering policy disappeared: $file");
        open my $fh, '<', $file or fail("Cannot read filtering policy: $file");
        my $bytes = do { local $/; <$fh> };
        close $fh;
        sha256_hex($bytes) eq $policy->{sha256} or fail("Filtering policy changed: $file");
    }
}
sub _build {
    my ($self, $receipt, $plan) = @_;
    return unless $receipt->{generation};
    $self->_validate_sources($plan);
    my $directory = "$self->{state}/stow/$receipt->{generation}";
    secure_directory($directory);
    my $ignore = "$directory/.stow-local-ignore";
    if (!exists_entry($ignore)) {
        sysopen my $fh, $ignore, O_WRONLY | O_CREAT | O_EXCL, 0600 or fail('Cannot create generated ignore metadata');
        print {$fh} "# Frozen overlay selection; do not apply default ignores again.\n";
        close $fh;
    }
    -f $ignore && !-l $ignore or fail('Generated ignore metadata was replaced');
    for my $entry (@{$plan->{targets}}) {
        my $target = normalized($entry->{target});
        my $path = "$directory/$target";
        secure_directory(dirname($path));
        my $text = File::Spec->abs2rel(b($entry->{owner}{source_entry}), dirname($path));
        if (exists_entry($path)) {
            -l $path && readlink($path) eq $text or fail("Generation entry conflict: $path");
        } else { symlink($text, $path) or fail("Cannot build relative source link: $path"); }
        $self->_point('build-entry');
    }
    $self->_validate_sources($plan);
    my $manifest = { %$plan, generation => $receipt->{generation} };
    write_json("$self->{state}/manifests/$receipt->{generation}.json", $manifest);
    $receipt->{manifest_sha256} = sha256_hex(json()->encode($manifest));
    $receipt->{links} = { map { my $target = normalized($_->{target});
        $_->{target} => u($self->_stow_link_text("$self->{state}/stow", $receipt->{generation}, $target)) } @{$plan->{targets}} };
    $self->_journal('built');
}
sub _transition {
    my ($self, $from, $to, $simulate, $extra_delete) = @_;
    my $operation = "$self->{state}/operations/$self->{pending}{id}";
    my $number = scalar @{$self->{pending}{runs}};
    my $record = { simulate => $simulate ? 1 : 0, started => time, pid => undef, exit_status => undef,
        stdout => u("$operation/$number.stdout.log"), stderr => u("$operation/$number.stderr.log"),
        options => { no_folding => 1, dir => u("$self->{state}/stow"), target => u($self->{home}) } };
    my $helper = dirname(dirname(__FILE__)) . '/stow_transition.pl';
    $helper = File::Spec->rel2abs($helper);
    my @command = ($self->{runtime}{interpreter}, $helper, $self->{runtime}{executable}, $self->{runtime}{version},
        "$self->{state}/stow", $self->{home}, $simulate ? 1 : 0,
        join(',', grep { defined && length } ($from->{generation}, @{$extra_delete || []})) || '-', $to->{generation} || '-');
    $record->{command} = [map { u($_) } @command];
    print STDERR 'Stow transition: ', json()->encode($record->{command}), "\n" if $self->{verbose};
    pipe(my $go_read, my $go_write) or fail('Cannot create Stow launch barrier');
    my $pid = fork();
    defined $pid or fail('Cannot fork Stow transition');
    if (!$pid) {
        $ENV{DFT_GUARD_FD} = $self->{guard}->inherited_fd;
        close $go_write;
        read($go_read, my $go, 1) == 1 or POSIX::_exit(125);
        close $go_read;
        open STDIN, '<', '/dev/null' or POSIX::_exit(125);
        open STDOUT, '>', b($record->{stdout}) or POSIX::_exit(125);
        open STDERR, '>', b($record->{stderr}) or POSIX::_exit(125);
        exec(@command) or POSIX::_exit(127);
    }
    close $go_read;
    $record->{pid} = $pid;
    push @{$self->{pending}{runs}}, $record;
    $self->_journal($simulate ? 'simulating' : 'applying');
    print {$go_write} 'g';
    close $go_write;
    waitpid($pid, 0);
    $record->{wait_status} = $?;
    $record->{exit_status} = ($record->{wait_status} & 127) ? 128 + ($record->{wait_status} & 127) : $record->{wait_status} >> 8;
    $record->{finished} = time;
    $self->_journal($record->{exit_status} == 0 ? ($simulate ? 'simulated' : 'stow-complete')
        : ($simulate ? 'simulation-failed' : 'stow-failed'));
    $record->{exit_status} == 0 or fail("Stow transition failed; retained journal and logs in $operation");
}
sub _verify {
    my ($self, $old, $new, $old_manifest, $new_manifest) = @_;
    $self->_check_targets($old, $new, $old_manifest, $new_manifest, 1);
    my %wanted = map { $_->{target} => 1 } @{$new_manifest->{targets}};
    for my $entry (@{$new_manifest->{targets}}) {
        my $target = normalized($entry->{target});
        my $path = "$self->{home}/$target";
        my $expected = $self->_home_text($new, $target);
        -l $path && readlink($path) eq $expected or fail("Post-Stow link verification failed: $path");
        $new->{links}{u($target)} = u($expected);
    }
    for my $entry (@{$old_manifest->{targets}}) {
        next if $wanted{$entry->{target}};
        !exists_entry("$self->{home}/" . normalized($entry->{target})) or fail('Obsolete target link remains');
    }
    $new->{ancestors} = $self->_check_targets($old, $new, $old_manifest, $new_manifest, 1);
}
sub _publish {
    my ($self, $receipt, $keep_lock) = @_;
    $self->_point('publication');
    write_json("$self->{state}/applied.json", $receipt);
    $self->_journal('published');
    $self->_point('after-publication');
    my $archive = "$self->{state}/operations/$self->{pending}{id}/completed.json";
    rename "$self->{state}/pending.json", $archive or fail('Cannot archive completed pending journal');
    $self->{guard}->published($receipt->{generation});
    $self->{guard}->finish unless $keep_lock;
}
sub _hooks {
    my ($self, $plan, $command) = @_;
    return unless $command && $command =~ /^(?:stow|restow)$/;
    for my $source (@{$plan->{sources}}) {
        my $directory = b($source->{root}) . '/hooks/post-stow.d';
        next unless -d $directory;
        opendir my $dh, $directory or do { warn "Warning: cannot read hooks in $directory: $!\n"; next; };
        my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        for my $name (@names) {
            my $hook = "$directory/$name";
            next unless -f $hook && -x $hook;
            local $ENV{DOTFILES_DIR} = b($source->{root});
            local $ENV{DOTFILETRACKER_SOURCE_ID} = b($source->{id});
            # Keep hook output off the command's JSON stdout, and keep the
            # target lock held until all synchronous hooks have returned.
            my $pid = fork();
            if (!defined $pid) { warn "Warning: cannot start post-stow hook $hook: $!\n"; next; }
            if (!$pid) {
                open STDIN, '<', '/dev/null' or POSIX::_exit(125);
                open STDOUT, '>&', \*STDERR or POSIX::_exit(125);
                $self->{guard}->exec_external($hook, $command);
            }
            waitpid($pid, 0);
            warn "Warning: post-stow hook $source->{id}:$name reported a problem (wait status $?).\n" if $?;
        }
    }
}
sub apply {
    my ($self, $discover, $command) = @_;
    $self->_begin('stack', 1);
    my $plan = $discover->();
    $self->_validate_plan($plan);
    my $old = read_json("$self->{state}/applied.json") || $self->_receipt(undef, undef);
    my $old_manifest = $self->_manifest($old);
    $self->_generation_entries($old, $old_manifest);
    my $parents = $self->_check_targets($old, {}, $old_manifest, $plan, 0);
    my $signature = sub { [map { { target => $_->{target}, owner => $_->{owner} } } @{$_[0]}] };
    if (json()->encode($signature->($old_manifest->{targets})) eq json()->encode($signature->($plan->{targets}))) {
        my $valid = eval { $self->_verify($old, $old, $old_manifest, $old_manifest); 1 };
        if ($valid) { $self->_hooks($plan, $command); $self->{guard}->finish; return { noop => 1, generation => $old->{generation} }; }
    }
    return $self->_start($old, $old_manifest, $plan, $parents, $command);
}
sub delete_applied {
    my ($self) = @_;
    $self->_begin('stack');
    my $old = read_json("$self->{state}/applied.json") || $self->_receipt(undef, undef);
    my $old_manifest = $self->_manifest($old);
    if (!$old->{generation}) {
        $self->{guard}->published(undef) if $self->{guard}{record}{owner_state};
        $self->{guard}->finish;
        return { noop => 1, generation => undef };
    }
    $self->_generation_entries($old, $old_manifest);
    my $empty = { targets => [], sources => [] };
    my $parents = $self->_check_targets($old, {}, $old_manifest, $empty, 0);
    return $self->_start($old, $old_manifest, $empty, $parents);
}
sub _start {
    my ($self, $old, $old_manifest, $plan, $parents, $command) = @_;
    my $id = identifier();
    my $new = $self->_receipt(@{$plan->{targets}} ? 'generation_' . identifier() : undef, undef);
    $self->_prepare_state;
    secure_directory("$self->{state}/operations/$id");
    $self->{pending} = { schema_version => 1, id => $id, pid => $$, started => time,
        target_root => u($self->{home}), state_dir => u($self->{state}), old => $old, new => $new,
        plan => $plan, parents_before => $parents, runs => [], phase => 'building', last_completed => 'validated',
        ($self->{migration} ? (migration => $self->{migration}) : ()) };
    # Durable intent precedes the ownership claim; the marker names this record
    # so a crash before pending.json publication still has a recovery inventory.
    write_json("$self->{state}/operations/$id/intent.json", $self->{pending});
    $self->{guard}->claim($id);
    $self->_point('journal');
    $self->_journal('building');
    $self->_point('build');
    $self->_build($new, $plan);
    my $new_manifest = $self->_manifest($new);
    $self->_remove_legacy if $self->{migration};
    $self->_transition($old, $new, 1);
    $self->_generation_entries($new, $new_manifest);
    $self->_generation_entries($old, $old_manifest);
    $self->_validate_sources($plan);
    $self->_check_targets($old, $new, $old_manifest, $new_manifest, 0);
    $self->_point('before-stow');
    $self->_transition($old, $new, 0);
    $self->_point('after-stow');
    $self->_point('verification');
    # Filtering is already frozen in the generated package. A managed home
    # ignore file may itself have transitioned; do not reinterpret it now.
    $self->_validate_sources($plan, 0);
    $self->_verify($old, $new, $old_manifest, $new_manifest);
    $self->_journal('verified');
    $self->_publish($new, 1);
    $self->_hooks($plan, $command);
    $self->{guard}->finish;
    return { generation => $new->{generation}, operation => $id };
}
sub preview {
    my ($self, $discover) = @_;
    $self->_begin('inspect');
    !$self->{guard}{record}{intent} && !read_json("$self->{state}/pending.json")
        or fail('Unfinished stack operation; recovery required before preview');
    my $plan = $discover->();
    $self->_validate_plan($plan);
    my $old = read_json("$self->{state}/applied.json") || $self->_receipt(undef, undef);
    my $old_manifest = $self->_manifest($old);
    $self->_generation_entries($old, $old_manifest);
    $self->_check_targets($old, {}, $old_manifest, $plan, 0);
    return { kind => 'overlay-preview', stow_simulation => JSON::PP::false, plan => $plan,
             previous_generation => $old->{generation} };
}
sub _validate_plan {
    my ($self, $plan) = @_;
    if ($self->{source_roots} && @{$self->{source_roots}}) {
        my @registered = sort map { u(abs_path($_)) } @{$self->{source_roots}};
        my @planned = sort map { $_->{root} } @{$plan->{sources}};
        json()->encode(\@registered) eq json()->encode(\@planned) or fail('Discovery changed the registered source set under the lock');
    }
    $plan->{target_root} eq u($self->{home}) or fail('Plan belongs to a different home');
    $self->_validate_sources($plan);
}
sub inspect_applied {
    my ($self) = @_;
    $self->_begin('inspect');
    my $receipt = read_json("$self->{state}/applied.json") || $self->_receipt(undef, undef);
    my $manifest = $self->_manifest($receipt);
    my @entries;
    for my $entry (@{$manifest->{targets}}) {
        my $target = normalized($entry->{target});
        my $owned = eval {
            $self->_parents($target, $receipt->{ancestors});
            my $path = "$self->{home}/$target";
            -l $path && readlink($path) eq $self->_home_text($receipt, $target);
        };
        push @entries, { %$entry, owned => $owned ? JSON::PP::true : JSON::PP::false };
    }
    return { generation => $receipt->{generation}, targets => \@entries,
        pending => ($self->{guard}{record}{intent} || read_json("$self->{state}/pending.json")) ? JSON::PP::true : JSON::PP::false };
}
sub writer_guard {
    my ($self, $preview, $paths, $write_root) = @_;
    $self->_begin($preview ? 'inspect' : 'stack', $self->{source_roots} && @{$self->{source_roots}});
    $self->_validate_sources({ sources => [map { {root => u($_)} } @{$self->{source_roots} || []}], targets => [] });
    !$self->{guard}{record}{intent} && !read_json("$self->{state}/pending.json") or fail('Unfinished stack operation; recovery required before utility writes');
    my $old = read_json("$self->{state}/applied.json") || $self->_receipt(undef, undef);
    my $manifest = $self->_manifest($old);
    $self->_generation_entries($old, $manifest);
    $self->_check_targets($old, {}, $manifest, { targets => [], sources => [] }, 0);
    my @protected = ($self->{state}, "$self->{home}/.dotfiletracker-lock", "$self->{home}/.dotfiletracker-owner.json",
        Dotfiletracker::TargetGuard::canonical_future(($ENV{XDG_CONFIG_HOME} || "$ENV{HOME}/.config") . '/dotfiletracker'),
        map { "$self->{home}/" . normalized($_->{target}) } @{$manifest->{targets}});
    for my $path (@{$paths || []}) {
        my $absolute = File::Spec->rel2abs($path);
        my $literal = Dotfiletracker::TargetGuard::canonical_future(dirname($absolute)) . '/' . File::Basename::basename($absolute);
        my @locations = ($literal);
        push @locations, abs_path($absolute) if -l $absolute && defined abs_path($absolute);
        for my $location (@locations) {
            !$write_root || within($location, $write_root) or fail("Utility destination escaped its selected source: $path");
            for my $protected (@protected) {
                (within($location, $protected) || within($protected, $location))
                    and fail("Utility destination overlaps managed HOME/control paths; choose a source checkout: $path");
            }
        }
    }
    return $self->{guard};
}
sub preview_delete {
    my ($self) = @_;
    $self->_begin('inspect');
    !$self->{guard}{record}{intent} && !read_json("$self->{state}/pending.json") or fail('Unfinished stack operation; recovery required');
    my $old = read_json("$self->{state}/applied.json") || $self->_receipt(undef, undef);
    my $manifest = $self->_manifest($old);
    $self->_generation_entries($old, $manifest);
    $self->_check_targets($old, {}, $manifest, { targets => [], sources => [] }, 0);
    return { kind => 'overlay-delete-preview', generation => $old->{generation}, targets => $manifest->{targets}, stow_simulation => JSON::PP::false };
}
sub _legacy_fold {
    my ($self, $target) = @_;
    for my $name (keys %{$self->{migration}{links} || {}}) {
        my $record = $self->{migration}{links}{$name};
        next unless $record->{folded} && within($target, b($name)) && $target ne b($name);
        my $path = "$self->{home}/" . b($name);
        return $name if -l $path && readlink($path) eq b($record->{text});
    }
    return;
}
sub _migration_inventory {
    my ($self, $plan, $from) = @_;
    my ($source_record) = grep { $_->{id} eq $from } @{$plan->{sources}};
    $source_record or fail('Migration requires --from with a registered source ID');
    my (%candidates, %links);
    for my $entry (@{$plan->{targets}}) {
        for my $owner ($entry->{owner}, @{$entry->{shadowed}}) {
            next unless $owner->{source_id} eq $from;
            $candidates{$entry->{target}} = $owner;
        }
    }
    for my $name (sort keys %candidates) {
        my $target = normalized($name);
        my $entry = b($candidates{$name}{source_entry});
        my $package_directory = b($source_record->{root}) . '/' . b($candidates{$name}{package_relative});
        my @parts = split m{/}, $target;
        my $prefix = '';
        for my $i (0 .. $#parts) {
            $prefix .= (length($prefix) ? '/' : '') . $parts[$i];
            my $path = "$self->{home}/$prefix";
            last unless exists_entry($path);
            if (-l $path) {
                my $source = $entry;
                $source = dirname($source) for $i + 1 .. $#parts;
                my $text = $self->_stow_link_text(dirname($package_directory), basename($package_directory), $prefix);
                readlink($path) eq $text or fail("Migration refuses unrelated link: $path");
                $links{u($prefix)} = { text => u($text), source_entry => u($source), folded => $i < $#parts ? 1 : 0 };
                last;
            }
            -d $path && $i < $#parts or fail("Migration preserves replacement/conflicting structure: $path");
        }
    }
    # A folded link exposes its entire subtree. Refuse to discard ignored or
    # inactive entries; the operator can unfold with legacy Stow first.
    for my $name (sort keys %links) {
        next unless $links{$name}{folded};
        my $scan;
        $scan = sub {
            my ($directory, $relative) = @_;
            opendir my $dh, $directory or fail("Cannot inspect folded migration tree: $directory");
            my @names = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
            closedir $dh;
            for my $child (@names) {
                my $source = "$directory/$child";
                my $target = "$relative/$child";
                if (-d $source && !-l $source) { $scan->($source, $target); }
                else {
                    my $candidate = $candidates{u($target)};
                    $candidate && b($candidate->{source_entry}) eq $source
                        or fail("Folded migration contains an unselected entry: $source; unfold with legacy restow before migration");
                }
            }
        };
        $scan->(b($links{$name}{source_entry}), b($name)); undef $scan;
    }
    return { from => $from, links => \%links };
}
sub migrate {
    my ($self, $discover, $from, $preview) = @_;
    $self->_begin($preview ? 'inspect' : 'stack', !$preview);
    !$self->{guard}{record}{intent} && !read_json("$self->{state}/pending.json") or fail('Unfinished stack operation; recovery required');
    my $old = read_json("$self->{state}/applied.json") || $self->_receipt(undef, undef);
    !$old->{generation} or fail('Migration requires a target without an applied stack generation');
    my $plan = $discover->();
    $self->_validate_plan($plan);
    $self->{migration} = $self->_migration_inventory($plan, $from);
    my $empty = { targets => [], sources => [] };
    my $parents = $self->_check_targets($old, {}, $empty, $plan, 0);
    return { kind => 'overlay-migration-preview', stow_simulation => JSON::PP::false,
        migration => $self->{migration}, plan => $plan } if $preview;
    return $self->_start($old, $empty, $plan, $parents, 'stow');
}
sub _remove_legacy {
    my ($self) = @_;
    $self->_journal('migration-unlinking');
    for my $name (sort keys %{$self->{migration}{links}}) {
        my $path = "$self->{home}/" . normalized($name);
        $self->_parents(normalized($name), $self->{pending}{parents_before});
        next unless exists_entry($path);
        -l $path && readlink($path) eq b($self->{migration}{links}{$name}{text})
            or fail("Migration link was replaced: $path");
        unlink($path) or fail("Cannot unlink recorded migration link: $path");
        $self->_point('migration-unlink');
    }
    $self->_journal('migration-unlinked');
}
sub _restore_legacy {
    my ($self) = @_;
    for my $name (sort keys %{$self->{migration}{links}}) {
        my $target = normalized($name);
        my $path = "$self->{home}/$target";
        my $record = $self->{migration}{links}{$name};
        $self->_parents($target, $self->{pending}{parents_before});
        if (exists_entry($path)) {
            next if -l $path && readlink($path) eq b($record->{text});
            # Stow only leaves real directories here when unfolding a legacy
            # folded link. Remove empty planned directories, deepest first.
            if ($record->{folded} && -d $path && !-l $path) {
                my %directories = ($target => 1);
                for my $entry (@{$self->{pending}{plan}{targets}}) {
                    my $parent = dirname(normalized($entry->{target}));
                    while (within($parent, $target)) {
                        $directories{$parent} = 1;
                        last if $parent eq $target;
                        $parent = dirname($parent);
                    }
                }
                for my $directory (sort { length($b) <=> length($a) } keys %directories) {
                    my $full = "$self->{home}/$directory";
                    next unless exists_entry($full);
                    -d $full && !-l $full && rmdir($full) or fail("Migration restore preserves nonempty/replaced directory: $full");
                }
            } else { fail("Migration restore preserves replacement: $path"); }
        }
        symlink(b($record->{text}), $path) or fail("Cannot restore recorded legacy link: $path");
        $self->_point('migration-restore-link');
    }
}
sub _remove_legacy_present {
    my ($self) = @_;
    $self->_journal('migration-reconciling');
    for my $name (sort keys %{$self->{migration}{links}}) {
        my $path = "$self->{home}/" . normalized($name);
        $self->_parents(normalized($name), $self->{pending}{parents_before});
        if (-l $path && readlink($path) eq b($self->{migration}{links}{$name}{text})) {
            unlink($path) or fail("Cannot remove recorded legacy link: $path");
        }
    }
}
sub recover {
    my ($self, $action) = @_;
    $action =~ /^(?:inspect|resume|restore)$/ or fail('Recovery action must be inspect, resume or restore');
    $self->_begin($action eq 'inspect' ? 'inspect' : 'recovery');
    my $pending = read_json("$self->{state}/pending.json");
    if (!$pending && $self->{guard}{record}{intent}) {
        my $id = $self->{guard}{record}{intent};
        $id =~ /^[a-f0-9]{32}$/ or fail('Invalid recovery intent identity');
        my $operation = "$self->{state}/operations/$id";
        $pending = read_json("$operation/completed.json") || read_json("$operation/intent.json");
    }
    $pending or fail('No pending operation to recover');
    $pending->{target_root} eq u($self->{home}) && $pending->{state_dir} eq u($self->{state}) &&
        $pending->{id} =~ /^[a-f0-9]{32}$/ or fail('Pending journal belongs to another target/state');
    return $pending if $action eq 'inspect';
    $self->{pending} = $pending;
    $self->{migration} = $pending->{migration};
    $self->_journal unless exists_entry("$self->{state}/pending.json");
    for my $run (@{$pending->{runs}}) {
        if (!defined $run->{exit_status} && $run->{pid} && kill(0, $run->{pid})) {
            fail('Recorded Stow process is still live; recovery will not force or clear its lock');
        }
    }
    my ($old, $new) = @$pending{qw(old new)};
    my $old_manifest = $self->_manifest($old);
    $self->_validate_sources($pending->{plan}, 0) if $action eq 'resume';
    if ($action eq 'resume' && !$new->{manifest_sha256} && $new->{generation}) { $self->_build($new, $pending->{plan}); }
    my $new_manifest = $new->{manifest_sha256} ? $self->_manifest($new) : { targets => [], sources => [] };
    $self->_generation_entries($old, $old_manifest);
    $self->_generation_entries($new, $new_manifest) if $new->{manifest_sha256};
    $self->_check_targets($old, $new, $old_manifest, $new_manifest, 1);
    if ($self->{migration}) {
        # Both forward and rollback recovery accept only the recorded original
        # links or the recorded generated inventory, never arbitrary source links.
        $self->_remove_legacy_present;
        $self->_transition({}, {}, 1, [$new->{generation}]) if $new->{manifest_sha256};
        $self->_transition({}, {}, 0, [$new->{generation}]) if $new->{manifest_sha256};
        if ($action eq 'restore') {
            $self->_restore_legacy;
            $self->_journal('verified');
            $self->_publish($old);
            return { recovered => $action, generation => undef, legacy_restored => JSON::PP::true };
        }
    }
    my ($from, $to, $from_manifest, $to_manifest) = $action eq 'resume'
        ? ($old, $new, $old_manifest, $new_manifest) : ($new, $old, $new_manifest, $old_manifest);
    # The interrupted transition may contain links from both generations. A
    # single controlled Stow operation unstows BOTH inventories before stowing
    # the requested one; ownership was checked against only those inventories.
    my @extra = $new->{manifest_sha256} && $new->{generation} ? ($new->{generation}) : ();
    $self->_transition($old, $to, 1, \@extra);
    $self->_check_targets($old, $new, $old_manifest, $new_manifest, 1);
    $self->_transition($old, $to, 0, \@extra);
    $self->_validate_sources($pending->{plan}, 0) if $action eq 'resume';
    $self->_verify($from, $to, $from_manifest, $to_manifest);
    $self->_journal('verified');
    $self->_publish($to);
    return { recovered => $action, generation => $to->{generation} };
}
1;
