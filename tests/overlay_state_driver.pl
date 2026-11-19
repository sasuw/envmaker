#!/usr/bin/env perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use lib dirname(dirname(abs_path(__FILE__))) . '/bin';
use Dotfiletracker::OverlayPlanner;
use Dotfiletracker::OverlayState;
use Dotfiletracker::StowRuntime qw(load_stow);
if (@ARGV == 1 && $ARGV[0] eq '--help') { print "Usage: overlay_state_driver.pl apply|delete [FAILPOINT]\nTest-only: requires an envmaker-state mktemp HOME marker.\n"; exit 0; }
my $home = abs_path($ENV{HOME});
defined $home && $home =~ m{/envmaker-state\.[^/]+/\d+/home$} && -f "$home/.overlay-state-test"
    or die "Refusing lifecycle driver outside an owned temporary test home\n";
my $repo = dirname(dirname(abs_path(__FILE__)));
my ($action, $failure) = @ARGV;
if ($action && $action =~ /^(?:external|internal)-worker$/) {
    # A real hook/rule/fallback starts a detached child. The lifecycle test is
    # its subreaper; FIFOs prove readiness and control both process lifetimes.
    local $SIG{ALRM} = sub { POSIX::_exit(124) }; alarm 45;
    my $base = "$home/../boundary";
    my $pid = $action eq 'external-worker' ? fork() : 0; defined $pid or die $!;
    if (!$pid) {
        alarm 45;
        open STDIN, '<', '/dev/null' or die $!;
        open STDOUT, '>', '/dev/null' or die $!;
        open STDERR, '>', '/dev/null' or die $!;
        open my $pid_file, '>', "$base/background.pid" or die $!;
        print {$pid_file} "$$\n"; close $pid_file;
        my @lock = stat "$home/.dotfiletracker-lock";
        my @fds;
        if (opendir my $dh, '/dev/fd') {
            for my $fd (grep { /^\d+$/ } readdir $dh) {
                my @actual = POSIX::fstat($fd);
                push @fds, 0 + $fd if @actual && @lock && $actual[0] == $lock[0] && $actual[1] == $lock[1];
            }
            closedir $dh;
        }
        open my $release, '<', "$base/background-release" or die $!;
        open my $ready, '>', "$base/background-ready" or die $!;
        print {$ready} JSON::PP->new->encode({ pid => $$, guard_env => exists $ENV{DFT_GUARD_FD} ? 1 : 0,
            lock_fds => \@fds }), "\n";
        close $ready;
        read($release, my $go, 1) == 1 or POSIX::_exit(125);
        POSIX::_exit(0);
    }
    open my $release, '<', "$base/sync-release" or die $!;
    open my $ready, '>', "$base/sync-ready" or die $!;
    print {$ready} "R\n"; close $ready;
    read($release, my $go, 1) == 1 or POSIX::_exit(125);
    print "selected\n"; # Discovery fallback output, harmless for hooks/rules.
    POSIX::_exit(0);
}
if ($action && $action eq 'completion') {
    shift @ARGV;
    open STDIN, '<', "$home/completion-input" or die $!;
    exec('bash', "$repo/util/add-zsh-completion.sh", @ARGV) or die $!;
}
if ($action && $action eq 'nested-preview') {
    my ($verified) = Dotfiletracker::OverlayPlanner::capture($^X, "$repo/bin/mutation_guard.pl", 'verify', 'legacy-preview');
    my ($detected, undef, $detect_error) = Dotfiletracker::OverlayPlanner::capture($^X, "$repo/bin/overlay_command.pl", '-', '-', 'detect');
    my $shared;
    {
        local $ENV{DFT_GUARD_FD};
        delete $ENV{DFT_GUARD_FD};
        ($shared) = Dotfiletracker::OverlayPlanner::capture($^X, "$repo/bin/mutation_guard.pl", 'run', 'legacy-preview', '--', 'true');
    }
    exit($verified && !$detected && !length($detect_error) && !$shared ? 0 : 1);
}
if ($action && $action eq 'entry-probe') {
    my (undef, $inherit, @command) = @ARGV;
    my $guard = Dotfiletracker::TargetGuard->new(mode => 'recovery');
    local $ENV{DFT_GUARD_FD};
    if ($inherit eq 'missing') { delete $ENV{DFT_GUARD_FD}; }
    else { $ENV{DFT_GUARD_FD} = $inherit eq 'forged' ? 999 : $guard->inherited_fd; }
    my ($ok, $output, $error) = Dotfiletracker::OverlayPlanner::capture(@command);
    my ($shared, $probe_error);
    {
        local $ENV{DFT_GUARD_FD};
        delete $ENV{DFT_GUARD_FD};
        ($shared, undef, $probe_error) = Dotfiletracker::OverlayPlanner::capture($^X, "$repo/bin/mutation_guard.pl", 'run', 'legacy-preview', '--', 'true');
    }
    $guard->finish;
    print Dotfiletracker::TargetGuard::json()->encode({ ok => $ok, output => $output, error => $error,
        independent_shared => $shared, probe_error => $probe_error }), "\n";
    exit 0;
}
$action && $action =~ /^(?:apply|delete|preview|migrate|migration-preview|ls|delete-preview)$/ or die "Invalid test-driver action\n";
my $version = $ENV{STOW_VERSION} || '2.4.1';
my $runtime = load_stow("/opt/stow-$version/bin/stow", $version);
my $inject = sub {
    my ($point, $state) = @_;
    return unless $failure;
    if ($failure eq 'old-link-receipt' && $point eq 'after-stow') {
        # Recreate the incomplete journal bug after real Stow wrote its own links.
        # This intentionally uses the old shortest-path formula, independently
        # of the fixed production helper, so documented recovery is exercised.
        my $receipt = $state->{pending}{new};
        for my $entry (@{$state->{pending}{plan}{targets}}) {
            my $target = Dotfiletracker::OverlayState::b($entry->{target});
            $receipt->{links}{$entry->{target}} = Dotfiletracker::OverlayState::u(File::Spec->abs2rel(
                "$state->{state}/stow/$receipt->{generation}/$target", dirname("$home/$target")));
        }
        $state->_journal('stow-complete');
        die "Injected old shortest-path receipt after real Stow\n";
    }
    if ($failure eq 'kill-after-stow' && $point eq 'after-stow') { kill 9, $$; die 'kill failed'; }
    if (($failure eq 'partial' || $failure eq 'stow-conflict') && $point eq 'before-stow') {
        my $entry = $state->{pending}{plan}{targets}[0];
        my $target = Dotfiletracker::OverlayState::b($entry->{target});
        my $path = "$home/$target";
        if ($failure eq 'partial') {
            unlink $path if -l $path;
            make_path(dirname($path));
            symlink $state->_home_text($state->{pending}{new}, $target), $path or die $!;
            die "Injected partial transition\n";
        }
        open my $fh, '>', $path or die $!;
        print {$fh} 'human replacement'; close $fh;
        return;
    }
    die "Injected $point failure\n" if $point eq $failure;
};
my @roots;
if ($action eq 'apply' || $action eq 'migrate') {
    my ($ok, $output, $error) = Dotfiletracker::OverlayPlanner::capture('bash', "$repo/tests/read_source_roots.sh");
    $ok or die $error;
    @roots = split /\0/, $output;
}
my $state = Dotfiletracker::OverlayState->new(runtime => $runtime, inject => $inject, source_roots => \@roots,
    mode => $action =~ /preview|^ls$/ ? 'inspect' : 'stack');
my $discover = sub {
    my ($ok, $out, $err) = Dotfiletracker::OverlayPlanner::capture('bash', "$repo/envmaker.sh", 'plan');
    $ok or die $err;
    return Dotfiletracker::TargetGuard::json()->decode($out);
};
my $result = $action eq 'delete' ? $state->delete_applied : $action eq 'preview'
    ? $state->preview($discover) : $action =~ /^migra/ ? $state->migrate($discover, 'generic', $action eq 'migration-preview')
    : $action eq 'ls' ? $state->inspect_applied : $action eq 'delete-preview' ? $state->preview_delete
    : $state->apply($discover, 'restow');
print Dotfiletracker::TargetGuard::json()->encode($result), "\n";
