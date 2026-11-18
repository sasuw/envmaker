package Dotfiletracker::OverlayPlanner;
use strict;
use warnings;
use feature 'fc';
use Cwd qw(abs_path getcwd);
use Digest::SHA qw(sha256_hex);
use Encode qw(decode FB_CROAK);
use Exporter 'import';
use Fcntl qw(:mode);
use File::Basename qw(dirname basename);
use IO::Select;
use IPC::Open3;
use JSON::PP;
use Symbol qw(gensym);
use Unicode::Normalize qw(NFC);
our @EXPORT_OK = qw(build_plan read_registry);

# Paths stay in filesystem byte form internally; JSON strings are Unicode.
# Invalid UTF-8 fails explicitly instead of silently changing a link's path.
sub text_path { my $bytes = $_[0]; return decode('UTF-8', $bytes, FB_CROAK); }
sub quote_path { return JSON::PP->new->allow_nonref->encode(text_path($_[0])); }
sub fail { die 'overlay: ' . join('', @_) . "\n"; }

sub read_registry {
    my ($fh) = @_;
    local $/ = "\0";
    my $field = sub {
        my $value = <$fh>;
        defined $value && $value =~ s/\0\z// or fail('Truncated discovery registry');
        return $value;
    };
    $field->() eq 'registry-v1' or fail('Unknown discovery registry format');
    my (@sources, @packages);
    while (1) {
        my $kind = $field->();
        last if $kind eq 'end';
        my ($id, $path) = ($field->(), $field->());
        if ($kind eq 'source') { push @sources, { id => $id, root => $path }; }
        elsif ($kind eq 'package') { push @packages, { id => $id, path => $path }; }
        else { fail('Unknown discovery record: ', $kind); }
    }
    !defined <$fh> or fail('Trailing discovery records');
    return (\@sources, \@packages);
}

sub capture {
    my (@command) = @_;
    my ($input, $output, $error) = (undef, undef, gensym());
    local $ENV{GIT_OPTIONAL_LOCKS} = 0;
    my $pid = open3($input, $output, $error, @command);
    close $input;
    my $select = IO::Select->new($output, $error);
    my ($stdout, $stderr) = ('', '');
    my $out_fd = fileno($output);
    while (my @ready = $select->can_read) {
        for my $fh (@ready) {
            my $bytes = sysread($fh, my $buffer, 65536);
            defined $bytes or fail('Cannot read provenance subprocess output: ', $!);
            if (!$bytes) { $select->remove($fh); close $fh; next; }
            if (fileno($fh) == $out_fd) { $stdout .= $buffer; }
            else { $stderr .= $buffer; }
        }
    }
    waitpid($pid, 0);
    return ($? == 0, $stdout, $stderr);
}

sub git_provenance {
    my ($root) = @_;
    my @git = ('git', '-c', 'core.fsmonitor=false', '-C', $root);
    my ($ok, $top) = capture(@git, 'rev-parse', '--show-toplevel');
    return { commit => undef, dirty => undef } unless $ok;
    $top =~ s/\n\z//;
    return { commit => undef, dirty => undef } unless abs_path($top) eq $root;
    my ($has_commit, $commit) = capture(@git, 'rev-parse', '--verify', 'HEAD');
    $commit =~ s/\n\z//;
    my ($status_ok, $status) = capture(@git, 'status', '--porcelain=v1', '-z', '--untracked-files=normal');
    $status_ok or fail('Cannot read source Git status: ', quote_path($root));
    return { commit => $has_commit ? $commit : undef,
             dirty => length($status) ? JSON::PP::true : JSON::PP::false };
}

sub policy_file {
    my ($file) = @_;
    -f $file or fail('Ignore/resource file must resolve to a regular file: ', quote_path($file));
    open my $fh, '<', $file or fail('Cannot read ignore/resource file ', quote_path($file), ': ', $!);
    binmode $fh;
    my $bytes = do { local $/; <$fh> };
    close $fh or fail('Cannot close ignore/resource file: ', quote_path($file));
    return ($bytes, { file => text_path($file), sha256 => sha256_hex($bytes) });
}

sub resource_policy {
    my (@paths) = @_;
    my (%seen, @resources);
    for my $file (@paths) {
        next if $seen{$file}++ || (!-e $file && !-l $file);
        my ($bytes, $record) = policy_file($file);
        my $line_number = 0;
        for my $line (split /\n/, $bytes) {
            ++$line_number;
            next if $line =~ /^\s*(?:#|$)/;
            fail('Unsupported Stow resource option in ', quote_path($file), ':', $line_number,
                 '; stack planning supports only empty/comment-only .stowrc files');
        }
        push @resources, $record;
    }
    return \@resources;
}

sub freeze_ignore_policy {
    my ($package, $stow, $cache) = @_;
    for my $file ("$package/.stow-local-ignore", "$ENV{HOME}/.stow-global-ignore") {
        # Match Stow precedence, including falling back for a dangling policy.
        # Read each policy once per plan and compile those exact frozen bytes.
        if (!exists $cache->{$file}) {
            $cache->{$file} = -e $file ? [policy_file($file)] : undef;
        }
        next unless defined $cache->{$file};
        my ($bytes, $record) = @{$cache->{$file}};
        open my $fh, '<', \$bytes or fail('Cannot read frozen ignore policy');
        my @regexps = $stow->get_ignore_regexps_from_fh($fh);
        close $fh;
        $stow->{frozen_ignore_regexps} = \@regexps;
        return $record;
    }
    {
        # This is the configured module's compiled default list, not a second
        # independent matcher. The differential fixtures cover this interface.
        no warnings 'once';
        $stow->{frozen_ignore_regexps} = [@Stow::default_global_ignore_regexps];
    }
    return { builtin => JSON::PP::true };
}

sub describe_owner {
    my ($owner) = @_;
    return $owner->{source_id} . ':' . $owner->{package_relative} . ' (' .
        JSON::PP->new->allow_nonref->encode($owner->{source_entry}) . ')';
}

sub build_plan {
    my ($sources, $packages, $runtime) = @_;
    my $home = abs_path($ENV{HOME}) or fail('Home target is not an existing directory');
    -d $home or fail('Home target is not a directory');
    my $resources = resource_policy("$ENV{HOME}/.stowrc", getcwd() . '/.stowrc');
    my (%source_by_id, @source_records, %roots);
    for my $source (@$sources) {
        my ($id, $root) = @$source{qw(id root)};
        $id =~ /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/ or fail('Invalid source ID');
        !$source_by_id{$id} or fail('Duplicate source ID: ', $id);
        my $physical = abs_path($root);
        defined $physical && -d $root && $physical eq $root
            or fail('Source root disappeared or changed: ', quote_path($root));
        my @stat = stat $root;
        !$roots{"$stat[0]:$stat[1]"}++ or fail('Repeated physical source root');
        my $record = { id => $id, root => text_path($root),
                       git => git_provenance($root) };
        $source_by_id{$id} = { root => $root, rank => scalar(@source_records) };
        push @source_records, $record;
    }
    @$sources or fail('Empty source registry');
    my (%entries, %portable_names, %seen_packages, %policy_cache, @package_records);
    my $add = sub {
        my ($target, $type, $owner) = @_;
        # Conservative portable namespace: reject casefold/NFC aliases even on
        # case-sensitive hosts, so a plan cannot become ambiguous on another OS.
        my $portable = fc(NFC(text_path($target)));
        if (my $prior = $portable_names{$portable}) {
            $prior->{target} eq $target or fail('Target spelling alias between ',
                quote_path($prior->{target}), ' from ', describe_owner($prior->{owner}),
                ' and ', quote_path($target), ' from ', describe_owner($owner));
        } else { $portable_names{$portable} = { target => $target, owner => $owner }; }
        my $node = $entries{$target};
        if (!$node) {
            $node = $entries{$target} = { type => $type, owners => [] };
        } elsif (($node->{type} eq 'directory') != ($type eq 'directory')) {
            fail('File/directory collision at ', quote_path($target), ' between ',
                 describe_owner($node->{owners}[0]), ' and ', describe_owner($owner));
        }
        if ($type ne 'directory') {
            for my $prior (@{$node->{owners}}) {
                $prior->{source_id} ne $owner->{source_id}
                    or fail('Same-source target ambiguity at ', quote_path($target),
                            ' between ', describe_owner($prior), ' and ', describe_owner($owner));
            }
        }
        push @{$node->{owners}}, $owner;
    };
    for my $package (sort {
            ($source_by_id{$a->{id}} // fail('Unknown package source'))->{rank} <=>
            ($source_by_id{$b->{id}} // fail('Unknown package source'))->{rank} ||
            $a->{path} cmp $b->{path}
        } @$packages) {
        my ($id, $package_path) = @$package{qw(id path)};
        my $source = $source_by_id{$id} or fail('Unknown package source: ', $id);
        my $root = $source->{root};
        index($package_path, "$root/") == 0 or fail('Package outside source: ', quote_path($package_path));
        my $physical = abs_path($package_path);
        defined $physical && $physical eq $package_path && -d $package_path && !-l $package_path
            or fail('Package directory is missing or traverses a symlink: ', quote_path($package_path));
        !$seen_packages{"$id\0$package_path"}++ or fail('Repeated package discovery: ', quote_path($package_path));
        my $relative_package = substr($package_path, length($root) + 1);
        my $stow = Dotfiletracker::FrozenStow->new(dir => dirname($package_path), target => $home, 'no-folding' => 1);
        my $policy = eval { freeze_ignore_policy($package_path, $stow, \%policy_cache) };
        $@ and fail('Invalid ignore policy for ', quote_path($package_path), ': ', $@);
        push @package_records, { source_id => $id, package_relative => text_path($relative_package),
            ignore_policy => $policy };
        my $walk;
        $walk = sub {
            my ($relative_dir) = @_;
            my $directory = length($relative_dir) ? "$package_path/$relative_dir" : $package_path;
            opendir my $dh, $directory or fail('Cannot enumerate ', quote_path($directory), ': ', $!);
            my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
            closedir $dh or fail('Cannot close directory: ', quote_path($directory));
            for my $name (@names) {
                my $target = length($relative_dir) ? "$relative_dir/$name" : $name;
                next if $target eq '.stow-local-ignore';
                my $ignored = eval { $stow->ignore(dirname($package_path), basename($package_path), $target) };
                $@ and fail('Invalid ignore policy for ', quote_path($package_path), ': ', $@);
                next if $ignored;
                my $entry = "$package_path/$target";
                my @stat = lstat $entry;
                @stat or fail('Source entry disappeared: ', quote_path($entry));
                my $type = S_ISDIR($stat[2]) ? 'directory' : S_ISREG($stat[2]) ? 'file' : S_ISLNK($stat[2]) ? 'symlink' : 'special';
                $type ne 'special' or fail('Unsupported special source entry: ', quote_path($entry));
                my $owner = { source_id => $id, package_relative => text_path($relative_package),
                    source_entry => text_path($entry), entry_type => $type, mode => S_IMODE($stat[2]) };
                if ($type eq 'symlink') {
                    my $text = readlink $entry;
                    defined $text or fail('Cannot read source link: ', quote_path($entry));
                    $owner->{link_text} = text_path($text);
                    -e $entry or fail('Broken or cyclic source link: ', quote_path($entry));
                    -f $entry or fail('Source link does not resolve to a regular file: ', quote_path($entry));
                }
                $add->($target, $type, $owner);
                $walk->($target) if $type eq 'directory';
            }
        };
        $walk->('');
        undef $walk;
    }
    my (@targets, @directories);
    for my $target (sort keys %entries) {
        my $node = $entries{$target};
        if ($node->{type} eq 'directory') {
            push @directories, { target => text_path($target), owners => $node->{owners} };
            next;
        }
        my @owners = @{$node->{owners}};
        my $winner = pop @owners;
        push @targets, { target => text_path($target), owner => $winner, shadowed => \@owners };
    }
    return { schema_version => 1, kind => 'overlay-plan', target_root => text_path($home),
        sources => \@source_records, packages => \@package_records, targets => \@targets,
        directories => \@directories, stow => $runtime, resource_files => $resources,
        resource_policy => 'comment-only', alias_policy => 'portable-casefold-nfc',
        application_enabled => JSON::PP::true };
}

package Dotfiletracker::FrozenStow;
our @ISA = ('Stow');
sub get_ignore_regexps { return @{$_[0]{frozen_ignore_regexps}}; }

1;
