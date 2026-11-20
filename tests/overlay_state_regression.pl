#!/usr/bin/env perl
use strict;
use warnings;
use Cwd qw(abs_path getcwd);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use JSON::PP;
use Fcntl qw(:DEFAULT F_GETFD F_SETFD FD_CLOEXEC);
use IO::Select;
use POSIX ();
use Test::More;
use lib dirname(dirname(abs_path(__FILE__))) . '/bin';
use Dotfiletracker::OverlayPlanner;
use Dotfiletracker::TargetGuard;
use Dotfiletracker::OverlayState;

use lib dirname(abs_path(__FILE__));
use FixtureLifecycle;

my $repo = dirname(dirname(abs_path(__FILE__)));
my $root = FixtureLifecycle::suite_root('envmaker-state.', $^X, abs_path(__FILE__), @ARGV);
my $serial = 0;
my $version = $ENV{STOW_VERSION} || '2.4.1';
open my $binary, '<', "/opt/stow-$version/bin/stow" or die $!;
my $shebang = <$binary>; close $binary; chomp $shebang;
$shebang =~ s/^#!//;
my $perl = $shebang eq '/usr/bin/env perl' ? $^X : $shebang;

sub write_file {
    my ($file, $bytes) = @_;
    make_path(dirname($file));
    open my $fh, '>', $file or die "$file: $!"; print {$fh} $bytes; close $fh;
}
sub read_file { open my $fh, '<', $_[0] or die $!; return do { local $/; <$fh> }; }
sub fixture {
    my $base = "$root/" . ++$serial;
    my $home = "$base/home";
    make_path("$home/.config/dotfiletracker", "$base/generic/parts", "$base/personal/parts", "$base/caller");
    write_file("$home/.overlay-state-test", 'fixture');
    write_file("$home/.config/dotfiletracker/config", "source.generic=$base/generic\nsource.personal=$base/personal\n");
    my %env = (%ENV, HOME => $home, XDG_CONFIG_HOME => "$home/.config", XDG_STATE_HOME => "$home/.local/state",
        XDG_DATA_HOME => "$home/.local/share", XDG_CACHE_HOME => "$home/.cache", TERM => 'dumb');
    delete @env{qw(BASH_ENV ENV DFT_GUARD_FD)};
    return { base => $base, home => $home, generic => "$base/generic", personal => "$base/personal", env => \%env,
             state => "$home/.local/state/dotfiletracker", cwd => "$base/caller" };
}
sub run {
    my ($f, @command) = @_;
    local %ENV = %{$f->{env}};
    my $cwd = getcwd(); chdir $f->{cwd} or die $!;
    my @result = Dotfiletracker::OverlayPlanner::capture(@command);
    chdir $cwd or die $!;
    return @result;
}
sub driver {
    my ($f, @arguments) = @_;
    return run($f, $perl, "$repo/tests/overlay_state_driver.pl", @arguments);
}
sub apply_ok {
    my ($f) = @_;
    my ($ok, $out, $err) = driver($f, 'apply');
    ok($ok, 'lifecycle apply succeeds') or diag($err, $out);
    return $ok ? JSON::PP->new->utf8->decode($out) : undef;
}
sub recover_ok {
    my ($f, $action) = @_;
    my ($ok, $out, $err) = run($f, 'bash', "$repo/envmaker.sh", 'recover', $action);
    ok($ok, "recovery $action succeeds") or diag($err, $out);
    return $out;
}
sub receipt { return Dotfiletracker::TargetGuard::read_json("$_[0]{state}/applied.json"); }
sub case_test {
    my ($name, $callback) = @_;
    return if @ARGV && !grep { $_ eq $name } @ARGV;
    subtest($name, $callback);
}

sub boundary_pipes {
    my ($f) = @_;
    make_path("$f->{base}/boundary");
    my %pipes;
    for my $name (qw(sync-ready sync-release background-ready background-release)) {
        my $file = "$f->{base}/boundary/$name";
        POSIX::mkfifo($file, 0600) == 0 or die $!;
        sysopen($pipes{$name}, $file, O_RDWR | O_NONBLOCK) or die $!;
    }
    return \%pipes;
}
sub boundary_ready {
    my ($fh) = @_;
    IO::Select->new($fh)->can_read(20) or die "External fixture readiness deadline exceeded\n";
    my $line = '';
    while ($line !~ /\n/) {
        sysread($fh, my $part, 4096) or die "External fixture readiness failed\n";
        $line .= $part;
    }
    return $line;
}
sub boundary_round {
    my ($f, $launch, $after_sync, $old_leak) = @_;
    my $pipes = boundary_pipes($f);
    my ($pid, $background, $reaped);
    my $error;
    eval {
        $pid = fork(); defined $pid or die $!;
        if (!$pid) {
            local %ENV = %{$f->{env}};
            chdir $f->{cwd} or POSIX::_exit(125);
            open STDIN, '<', '/dev/null' or POSIX::_exit(125);
            open STDOUT, '>', "$f->{base}/boundary/stdout" or POSIX::_exit(125);
            open STDERR, '>', "$f->{base}/boundary/stderr" or POSIX::_exit(125);
            $launch->();
            POSIX::_exit(127);
        }
        $background = JSON::PP->new->decode(boundary_ready($pipes->{'background-ready'}));
        boundary_ready($pipes->{'sync-ready'});
        my $clean = !$background->{guard_env} && !@{$background->{lock_fds}};
        diag('old leak: guard environment=', $background->{guard_env}, ', lock descriptor count=', scalar @{$background->{lock_fds}}) if $old_leak;
        is($clean ? 1 : 0, $old_leak ? 0 : 1, 'external descendant has no guard environment or lock descriptor (old leak fails)');
        my ($overlap, undef, $diagnostic) = run($f, $perl, "$repo/bin/mutation_guard.pl", 'run', 'legacy', '--', 'true');
        ok(!$overlap && $diagnostic =~ /lock is held/, 'independent writer excluded throughout synchronous external execution');
        like($diagnostic, qr/background process.*open lock descriptor/, 'contention describes inherited descriptor as a possible cause');
        syswrite($pipes->{'sync-release'}, 'G') == 1 or die $!;
        local $SIG{ALRM} = sub { die "External operation exit deadline exceeded\n" }; alarm 20;
        waitpid($pid, 0) == $pid or die $!;
        my $status = $?; $reaped = 1; alarm 0;
        is($status, 0, 'first operation exits successfully') or diag(read_file("$f->{base}/boundary/stderr"));
        $after_sync->();
        is(waitpid($background->{pid}, POSIX::WNOHANG()), 0, 'background descendant is still alive and awaits release');
        alarm 20;
        my ($next, undef, $err) = run($f, 'bash', "$repo/envmaker.sh", '--yes', 'execstow', 'restow');
        alarm 0;
        is($next ? 1 : 0, $old_leak ? 0 : 1, 'immediate second writer succeeds while descendant lives (old leak fails)') or diag($err);
        1;
    } or $error = $@;
    # Release/reap by captured PID on success and failure. The caller's alarm
    # bounds command capture; no fixed sleep establishes readiness or success.
    syswrite($pipes->{'sync-release'}, 'G');
    syswrite($pipes->{'background-release'}, 'G');
    local $SIG{ALRM} = sub { die "External fixture teardown deadline exceeded\n" }; alarm 50;
    waitpid($pid, 0) if $pid && !$reaped;
    if (!$background && -f "$f->{base}/boundary/background.pid") {
        my $child_pid = read_file("$f->{base}/boundary/background.pid");
        chomp $child_pid;
        $child_pid =~ /^\d+$/ or die 'Invalid owned background PID';
        $background = { pid => $child_pid };
    }
    if ($background) {
        is(waitpid($background->{pid}, 0), $background->{pid}, 'owned background descendant reaped by PID');
        is($?, 0, 'background descendant exits on explicit release');
    }
    close $_ for values %$pipes;
    alarm 0;
    die $error if $error;
}
sub enable_boundary_reaper {
    # Linux test infrastructure only; lock release and exclusion are proved by
    # portable flock/FIFO handshakes, without relying on /proc inspection.
    return 0 unless $^O eq 'linux';
    return 0 unless eval { require 'syscall.ph'; 1 };
    return syscall(&SYS_prctl, 36, 1, 0, 0, 0) == 0; # PR_SET_CHILD_SUBREAPER
}

case_test 'external descriptor boundary across stack legacy hooks rules and fallbacks' => sub {
    plan skip_all => 'Linux child subreaper required to reap detached fixture descendants' unless enable_boundary_reaper();
    for my $variant ($ENV{DFT_TEST_REVERSE} ? qw(nested-legacy legacy nested-stack stack) : qw(stack nested-stack legacy nested-legacy)) {
        my $mode = $variant;
        my $nested = $mode =~ s/^nested-//;
        for my $entry ($ENV{DFT_TEST_REVERSE} ? qw(fallback rule hook) : qw(hook rule fallback)) {
            subtest "$variant $entry" => sub {
                my $f = fixture();
                write_file("$f->{generic}/common/pkg/.setting", 'source');
                if ($mode eq 'legacy') {
                    write_file("$f->{home}/.config/dotfiletracker/config", "dotfiles_dir=$f->{generic}\n");
                }
                # The fallback entry is the built-in hostname selector, the
                # only ruleless part name discovery executes.
                my $script = $entry eq 'hook' ? "$f->{generic}/hooks/post-stow.d/10-boundary"
                    : $entry eq 'rule' ? "$f->{generic}/rules/selected" : "$f->{base}/tools/hostname";
                make_path("$f->{generic}/parts/selected") if $entry eq 'rule';
                make_path("$f->{generic}/parts/hostname/selected") if $entry eq 'fallback';
                $f->{env}{PATH} = "$f->{base}/tools:$f->{env}{PATH}";
                write_file($script, "#!/usr/bin/env bash\n" . <<'BASH' . "exec '$perl' '$repo/tests/overlay_state_driver.pl' external-worker\n");
[[ ! ${DFT_GUARD_FD+x} ]] || exit 91
# Inspect the shell itself before exec/CLOEXEC could hide an extra copy.
for guard_handle in /dev/fd/*; do
    if [[ "$guard_handle" -ef "$HOME/.dotfiletracker-lock" ]]; then exit 92; fi
done
BASH
                chmod 0755, $script or die $!;
                local $SIG{ALRM} = sub { die "External boundary round deadline exceeded\n" }; alarm 60;
                boundary_round($f, sub {
                    my @command = ('bash', "$repo/envmaker.sh", '--yes', 'execstow', 'restow');
                    @command = ($perl, "$repo/bin/mutation_guard.pl", 'run', 'legacy', '--', @command) if $nested;
                    exec { $command[0] } @command;
                }, sub {
                    write_file($script, "#!/bin/sh\nprintf 'selected\\n'\n");
                }, 0);
                alarm 0;
            };
        }
    }
};

case_test 'ruleless parts never execute their name in legacy and stack modes' => sub {
    # Only hostname and ostype run a built-in selector;
    # application checks children with command -v; every other part is inactive.
    for my $mode (qw(legacy stack)) {
        for my $nested (0, 1) {
            my $f = fixture();
            write_file("$f->{home}/.config/dotfiletracker/config", "dotfiles_dir=$f->{generic}\n") if $mode eq 'legacy';
            my $log = "$f->{base}/tripwire.log";
            for my $name (qw(selector application demoapp)) {
                write_file("$f->{base}/tools/$name", "#!/bin/sh\nprintf '%s\\n' '$name' >> '$log'\nprintf 'selected\\n'\n");
                chmod 0755, "$f->{base}/tools/$name" or die $!;
            }
            $f->{env}{PATH} = "$f->{base}/tools:$f->{env}{PATH}";
            write_file("$f->{generic}/parts/selector/selected/pkg/.selector-choice", 'executed');
            # parts/unlisted is not a command: the old fallback scanned its children.
            write_file("$f->{generic}/parts/unlisted/demoapp/pkg/.scanned-choice", 'scanned');
            write_file("$f->{generic}/parts/application/demoapp/pkg/.demoapp-choice", 'present');
            write_file("$f->{generic}/common/pkg/.shared-choice", 'shared');
            my @prefix = $nested ? ($perl, "$repo/bin/mutation_guard.pl", 'run', 'legacy', '--') : ();
            my ($listed, $out, $err) = run($f, @prefix, 'bash', "$repo/envmaker.sh", 'listdirs');
            ok($listed, "$mode nested=$nested lists directories") or diag($err);
            unlike($out, qr{/parts/(?:selector|unlisted)}, 'ruleless unlisted parts are not selected or scanned');
            like($out, qr{\Q$f->{generic}\E/parts/application/demoapp(?:\n|$)}, 'application child selected by presence');
            my ($applied, undef, $error) = run($f, @prefix, 'bash', "$repo/envmaker.sh", '--yes', 'execstow', 'restow');
            ok($applied, 'real guarded restow succeeds') or diag($error);
            is(read_file("$f->{home}/.demoapp-choice"), 'present', 'application package is installed');
            ok(!-e "$f->{home}/.selector-choice" && !-e "$f->{home}/.scanned-choice", 'ruleless part packages are not installed');
            ok(!-e $log, 'no ruleless part name or application child was executed')
                or diag(read_file($log));
        }
    }
};

case_test 'Bash function fallbacks select OS directories in legacy and stack modes' => sub {
    for my $mode (qw(legacy stack)) {
        for my $nested (0, 1) {
            my $f = fixture();
            write_file("$f->{home}/.config/dotfiletracker/config", "dotfiles_dir=$f->{generic}\n") if $mode eq 'legacy';
            write_file("$f->{base}/os_probe.sh", "source \"\$1/bin/common.sh\"\nostype\n");
            my ($probed, $os) = run($f, 'bash', "$f->{base}/os_probe.sh", $repo);
            ok($probed, 'source-local OS function is available');
            chomp $os;
            for my $candidate (qw(linux macos bsd solaris windows)) {
                write_file("$f->{generic}/parts/ostype/$candidate/pkg/.os-choice", $candidate);
            }
            write_file("$f->{generic}/common/pkg/.shared-choice", 'shared');
            my @prefix = $nested ? ($perl, "$repo/bin/mutation_guard.pl", 'run', 'legacy', '--') : ();
            my ($listed, $out, $err) = run($f, @prefix, 'bash', "$repo/envmaker.sh", 'listdirs');
            ok($listed, "$mode nested=$nested lists directories") or diag($err);
            like($out, qr/\Q$f->{generic}\/parts\/ostype\/$os\E(?:\n|$)/, 'function output selects the OS directory');
            my ($applied, undef, $error) = run($f, @prefix, 'bash', "$repo/envmaker.sh", '--yes', 'execstow', 'restow');
            ok($applied, 'real guarded discovery succeeds, including the nested stack plan') or diag($error);
            is(-f "$f->{home}/.os-choice" ? read_file("$f->{home}/.os-choice") : undef, $os, 'OS package is installed');
            is(read_file("$f->{home}/.shared-choice"), 'shared', 'common package is also installed');
        }
    }
};

case_test 'shebangless rules and legacy hooks retain Bash execution' => sub {
    for my $mode (qw(legacy stack)) {
        for my $nested (0, 1) {
            my $f = fixture();
            write_file("$f->{home}/.config/dotfiletracker/config", "dotfiles_dir=$f->{generic}\n") if $mode eq 'legacy';
            write_file("$f->{generic}/parts/selected/pkg/.bash-rule-choice", 'selected');
            my $body = <<'BASH';
[[ -n ${BASH_VERSION:-} && ! ${DFT_GUARD_FD+x} ]] || exit 91
values=(bash execution)
[[ ${values[1]} == execution ]] || exit 92
for guard_handle in /dev/fd/*; do
    if [[ "$guard_handle" -ef "$HOME/.dotfiletracker-lock" ]]; then exit 93; fi
done
BASH
            my $rule = "$f->{generic}/rules/selected";
            write_file($rule, $body . "printf 'rule\\n' >> \"\$HOME/bash-execution\"\n");
            chmod 0755, $rule or die $!;
            if ($mode eq 'legacy') {
                my $hook = "$f->{generic}/hooks/post-stow.d/10-bash";
                write_file($hook, $body . "printf 'hook:%s\\n' \"\$1\" >> \"\$HOME/bash-execution\"\n");
                chmod 0755, $hook or die $!;
            }
            my @prefix = $nested ? ($perl, "$repo/bin/mutation_guard.pl", 'run', 'legacy', '--') : ();
            my ($ok, undef, $err) = run($f, @prefix, 'bash', "$repo/envmaker.sh", '--yes', 'execstow', 'restow');
            ok($ok, "$mode nested=$nested applies shebangless selection") or diag($err);
            is(-f "$f->{home}/.bash-rule-choice" ? read_file("$f->{home}/.bash-rule-choice") : undef,
                'selected', 'shebangless Bash rule selects its package');
            is(-f "$f->{home}/bash-execution" ? read_file("$f->{home}/bash-execution") : undef,
                $mode eq 'legacy' ? "rule\nhook:restow\n" : "rule\n", 'rule and legacy hook execute in Bash without guard copies');
        }
    }
};

case_test 'external boundary closes original and verified duplicate with old leak negative control' => sub {
    plan skip_all => 'Linux child subreaper required to reap detached fixture descendants' unless enable_boundary_reaper();
    for my $old_leak ($ENV{DFT_TEST_REVERSE} ? (1, 0) : (0, 1)) {
        my $f = fixture();
        write_file("$f->{home}/.config/dotfiletracker/config", "dotfiles_dir=$f->{generic}\n");
        local %ENV = %{$f->{env}};
        my @occupied;
        for (1 .. 16) { open my $fh, '<', '/dev/null' or die $!; push @occupied, $fh; }
        my $guard = Dotfiletracker::TargetGuard->new(mode => 'legacy');
        cmp_ok(fileno($guard->{fh}), '>', 16, 'descriptor number is discovered, not fixed at three');
        my $parent_flags = fcntl($guard->{fh}, F_GETFD, 0);
        ok($parent_flags & FD_CLOEXEC, 'parent descriptor starts close-on-exec');
        boundary_round($f, sub {
            $ENV{DFT_GUARD_FD} = $guard->inherited_fd;
            my $verified = Dotfiletracker::TargetGuard->for_entry(mode => 'legacy');
            fileno($verified->{fh}) != $ENV{DFT_GUARD_FD} or die 'verification must duplicate the inherited descriptor';
            fcntl($verified->{fh}, F_SETFD, 0) or die $!; # Recreate both inheritable copies of the old leak.
            my @command = ($perl, "$repo/tests/overlay_state_driver.pl", 'external-worker');
            if ($old_leak) { exec { $command[0] } @command; }
            else { $verified->exec_external(@command); }
        }, sub {
            is(fcntl($guard->{fh}, F_GETFD, 0), $parent_flags, 'child inheritance leaves exact parent flags intact');
            $guard->finish;
        }, $old_leak);
    }
};

case_test 'internal mutator retains inherited lock after its guarding parent exits' => sub {
    plan skip_all => 'Linux child subreaper required to reap detached fixture descendants' unless enable_boundary_reaper();
    my $f = fixture();
    my $pipes = boundary_pipes($f);
    my $pid = fork(); defined $pid or die $!;
    if (!$pid) {
        local %ENV = %{$f->{env}};
        open STDIN, '<', '/dev/null' or POSIX::_exit(125);
        open STDOUT, '>', '/dev/null' or POSIX::_exit(125);
        open STDERR, '>', '/dev/null' or POSIX::_exit(125);
        exec $perl, "$repo/bin/mutation_guard.pl", 'run', 'legacy', '--',
            $perl, "$repo/tests/overlay_state_driver.pl", 'internal-worker' or POSIX::_exit(127);
    }
    my ($worker, $error, $reaped);
    eval {
        $worker = JSON::PP->new->decode(boundary_ready($pipes->{'background-ready'}));
        ok($worker->{guard_env}, 'internal mutator receives the explicit guard handoff');
        kill 'TERM', $pid;
        local $SIG{ALRM} = sub { die "Guard parent exit deadline exceeded\n" }; alarm 20;
        waitpid($pid, 0) == $pid or die $!;
        $reaped = 1;
        is($? & 127, POSIX::SIGTERM(), 'owned guarding parent exits on its captured PID');
        my ($overlap, undef, $err) = run($f, $perl, "$repo/bin/mutation_guard.pl", 'run', 'legacy', '--', 'true');
        ok(!$overlap && $err =~ /lock is held/, 'actual internal child keeps exclusion after parent exit');
        alarm 0;
        1;
    } or $error = $@;
    syswrite($pipes->{'background-release'}, 'G');
    local $SIG{ALRM} = sub { die "Internal fixture teardown deadline exceeded\n" }; alarm 50;
    waitpid($pid, 0) unless $reaped;
    if (!$worker && -f "$f->{base}/boundary/background.pid") {
        my $child_pid = read_file("$f->{base}/boundary/background.pid");
        chomp $child_pid;
        $child_pid =~ /^\d+$/ or die 'Invalid owned internal PID';
        $worker = { pid => $child_pid };
    }
    if ($worker) {
        is(waitpid($worker->{pid}, 0), $worker->{pid}, 'owned internal mutator reaped by PID');
        is($?, 0, 'internal mutator completes on explicit release');
    }
    close $_ for values %$pipes;
    alarm 0;
    die $error if $error;
    my ($released) = run($f, $perl, "$repo/bin/mutation_guard.pl", 'run', 'legacy', '--', 'true');
    ok($released, 'lock releases when the actual mutator exits');
};

sub local_targets_fixture {
    my ($inside_home) = @_;
    my $f = fixture();
    if ($inside_home) {
        for my $source (qw(generic personal)) { $f->{$source} = "$f->{home}/.local/share/checkouts/$source"; }
        make_path("$f->{generic}/parts", "$f->{personal}/parts");
        write_file("$f->{home}/.config/dotfiletracker/config", "source.generic=$f->{generic}\nsource.personal=$f->{personal}\n");
    }
    make_path("$f->{home}/.local/share", "$f->{personal}/parts/application");
    write_file("$f->{generic}/common/pkg/.local/bin/demo", 'generic');
    write_file("$f->{generic}/common/pkg/.local/share/app/data", 'data');
    write_file("$f->{personal}/common/pkg/.local/bin/demo", 'personal');
    return $f;
}

case_test 'Stow home link text under local state covers apply inspection writers and deletion' => sub {
    for my $inside_home (0, 1) {
        my $f = local_targets_fixture($inside_home);
        my ($preview) = run($f, 'bash', "$repo/envmaker.sh", '--dry-run', 'execstow', 'restow');
        ok($preview && !-e $f->{state}, 'local-target preview creates no state');
        my $applied = apply_ok($f) or next;
        for my $target ('.local/bin/demo', '.local/share/app/data') {
            my $depth = $target eq '.local/bin/demo' ? 2 : 3;
            my $expected = ('../' x $depth) . ".local/state/dotfiletracker/stow/$applied->{generation}/$target";
            is(readlink("$f->{home}/$target"), $expected, 'actual Stow uses target-root-relative text');
            is(receipt($f)->{links}{$target}, $expected, 'receipt matches actual Stow literal text');
        }
        my ($listed, $json) = run($f, 'bash', "$repo/envmaker.sh", 'ls');
        ok($listed && !(grep { !$_->{owned} } @{JSON::PP->new->utf8->decode($json)->{targets}}), 'ls owns all local targets');
        ok(apply_ok($f)->{noop}, 'local-target no-op verifies ownership');
        my ($again) = driver($f, 'preview');
        ok($again, 'apply preview recognizes local ownership');
        for my $utility (qw(remove_function_keyword convert_aliases_to_functions)) {
            my ($written, undef, $err) = run($f, 'bash', "$repo/util/$utility.sh", '--source', 'personal');
            ok($written, 'rewrite preflight recognizes local ownership') or diag($err);
        }
        write_file("$f->{home}/completion-input", "#compdef demo\n");
        my ($completion, undef, $error) = driver($f, 'completion', '--source', 'personal', '--no-stow', 'demo');
        ok($completion, 'completion writer recognizes local ownership') or diag($error);
        unlink "$f->{personal}/common/pkg/.local/bin/demo" or die $!;
        apply_ok($f);
        is(read_file("$f->{home}/.local/bin/demo"), 'generic', 'local target reconciles to lower owner');
        rename $f->{generic}, "$f->{generic}-gone" or die $!;
        rename $f->{personal}, "$f->{personal}-gone" or die $!;
        my ($delete_preview) = run($f, 'bash', "$repo/envmaker.sh", '--yes', '--dry-run', 'del');
        ok($delete_preview && -l "$f->{home}/.local/bin/demo", 'local delete preview works without sources');
        my ($deleted, undef, $err) = run($f, 'bash', "$repo/envmaker.sh", '--yes', 'execstow', 'delete');
        ok($deleted && !-l "$f->{home}/.local/bin/demo" && !-l "$f->{home}/.local/share/app/data", 'local inventory deletion works without sources') or diag($err);
    }
};

case_test 'direct and folded local migration recognizes Stow text with neighboring source roots' => sub {
    for my $inside_home (0, 1) {
        for my $folded (0, 1) {
            my $f = local_targets_fixture($inside_home);
            my ($stowed, undef, $err) = run($f, "/opt/stow-$version/bin/stow", '--dir', "$f->{generic}/common", '--target', $f->{home},
                ($folded ? () : ('--no-folding')), 'pkg');
            ok($stowed, 'legacy local targets stowed') or diag($err);
            my ($preview, $out, $error) = run($f, 'bash', "$repo/envmaker.sh", '--dry-run', 'migrate', '--from', 'generic');
            ok($preview, 'migration preview recognizes actual Stow text') or diag($error);
            ok(!-e $f->{state}, 'migration preview makes no state');
            my ($migrated, undef, $diagnostic) = run($f, 'bash', "$repo/envmaker.sh", '--yes', 'migrate', '--from', 'generic');
            ok($migrated, 'direct/folded local migration succeeds') or diag($diagnostic);
            is(read_file("$f->{home}/.local/bin/demo"), 'personal', 'migration installs higher local owner');
            my ($listed, $json) = run($f, 'bash', "$repo/envmaker.sh", 'ls');
            ok($listed && !(grep { !$_->{owned} } @{JSON::PP->new->utf8->decode($json)->{targets}}), 'migration ls recognizes local links');
            is(read_file("$f->{generic}/common/pkg/.local/bin/demo"), 'generic', 'generic source unchanged');
            is(read_file("$f->{personal}/common/pkg/.local/bin/demo"), 'personal', 'personal source unchanged');
        }
    }
};

case_test 'migrate again after deletion and restoration of a legacy fold' => sub {
    for my $old_receipt (0, 1) {
        my $f = fixture();
        my $fold = "$f->{home}/.tool";
        my $entry = "$fold/config";
        write_file("$f->{generic}/common/pkg/.tool/config", 'generic');
        write_file("$f->{personal}/common/pkg/.tool/config", 'personal');
        my @legacy = ("/opt/stow-$version/bin/stow", '--dir', "$f->{generic}/common",
            '--target', $f->{home}, 'pkg');
        my @envmaker = ('bash', "$repo/envmaker.sh");
        my ($installed) = run($f, @legacy);
        ok($installed && -l $fold, 'legacy package initially folded');
        my $fold_text = readlink($fold);
        my ($first, undef, $first_err) = run($f, @envmaker, '--yes', 'migrate', '--from', 'generic');
        ok($first, 'first migration succeeds') or diag($first_err);
        is(read_file($entry), 'personal', 'first migration installs higher owner');
        my $prior = receipt($f);
        my ($deleted, undef, $delete_err) = run($f, @envmaker, '--yes', 'del');
        ok($deleted, 'recorded generation deletion succeeds') or diag($delete_err);
        my $empty = receipt($f);
        if ($old_receipt) {
            $empty->{ancestors} = $prior->{ancestors};
            write_file("$f->{state}/applied.json", JSON::PP->new->utf8->encode($empty));
        } else {
            is_deeply($empty->{ancestors}, {}, 'empty receipt owns no ancestors');
        }
        if (-d $fold) {
            rename($fold, "$f->{base}/held former ancestor") or die $!;
        }
        symlink($fold_text, $fold) or die $!;
        my ($second, undef, $second_err) = run($f, @envmaker, '--yes', 'migrate', '--from', 'generic');
        ok($second, 'migration succeeds after exact legacy fold restoration') or diag($second_err);
        my ($listed, $out) = run($f, @envmaker, 'ls');
        my @targets = $listed ? @{JSON::PP->new->utf8->decode($out)->{targets}} : ();
        ok($listed && @targets == 1 && $targets[0]{owned}, 'ls records renewed ownership');
    }
};

case_test 'recover old shortest-path receipts after real Stow installed local targets' => sub {
    for my $operation (qw(apply migrate-direct migrate-folded)) {
        for my $action (qw(resume restore)) {
            my $f = local_targets_fixture(0);
            my %legacy;
            if ($operation ne 'apply') {
                my ($ok) = run($f, "/opt/stow-$version/bin/stow", '--dir', "$f->{generic}/common", '--target', $f->{home},
                    ($operation eq 'migrate-direct' ? ('--no-folding') : ()), 'pkg');
                ok($ok, 'legacy local migration fixture');
                for my $target ($operation eq 'migrate-direct' ? ('.local/bin/demo', '.local/share/app/data') : ('.local/bin', '.local/share/app')) {
                    $legacy{$target} = readlink "$f->{home}/$target";
                }
            }
            my ($ok, undef, $err) = driver($f, $operation eq 'apply' ? 'apply' : 'migrate', 'old-link-receipt');
            ok(!$ok && $err =~ /Injected old shortest-path receipt/, 'old defective receipt retained after actual Stow');
            my $pending = Dotfiletracker::TargetGuard::read_json("$f->{state}/pending.json");
            is($pending->{phase}, 'stow-complete', 'recreates the reviewed stuck phase');
            isnt(readlink("$f->{home}/.local/bin/demo"), $pending->{new}{links}{'.local/bin/demo'}, 'actual Stow link differs from defective recorded text');
            recover_ok($f, 'inspect');
            recover_ok($f, $action);
            ok(!-e "$f->{state}/pending.json", 'documented recovery archives stuck operation');
            if ($action eq 'resume') {
                is(read_file("$f->{home}/.local/bin/demo"), 'personal', 'resume finishes local overlay');
                for my $target ('.local/bin/demo', '.local/share/app/data') {
                    is(receipt($f)->{links}{$target}, readlink("$f->{home}/$target"), 'recovery publishes upgraded receipt text');
                }
                ok(apply_ok($f)->{noop}, 'resumed local generation supports normal no-op apply');
            } elsif ($operation eq 'apply') {
                ok(!-l "$f->{home}/.local/bin/demo" && !-l "$f->{home}/.local/share/app/data", 'restore removes first-apply local links');
                apply_ok($f);
            } else {
                for my $target (sort keys %legacy) { is(readlink("$f->{home}/$target"), $legacy{$target}, 'restore reinstates exact legacy local link'); }
                my ($migrated, undef, $error) = run($f, 'bash', "$repo/envmaker.sh", '--yes', 'migrate', '--from', 'generic');
                ok($migrated, 'restored migration can be executed normally after recovery') or diag($error);
            }
        }
    }
    my $f = local_targets_fixture(0);
    driver($f, 'apply', 'old-link-receipt');
    my $pending = Dotfiletracker::TargetGuard::read_json("$f->{state}/pending.json");
    my $replacement = $pending->{new}{links}{'.local/bin/demo'};
    unlink "$f->{home}/.local/bin/demo" or die $!;
    symlink $replacement, "$f->{home}/.local/bin/demo" or die $!;
    for my $action (qw(resume restore)) {
        my ($ok, undef, $error) = run($f, 'bash', "$repo/envmaker.sh", 'recover', $action);
        ok(!$ok && $error =~ /preserving replacement/, 'receipt compatibility does not adopt a shortened replacement home link');
        is(readlink("$f->{home}/.local/bin/demo"), $replacement, 'replacement literal text preserved');
    }
};


case_test 'real generations, live edits, no-op, inheritance and deletion without sources' => sub {
    my $f = fixture();
    write_file("$f->{generic}/common/lower/.setting", 'lower');
    write_file("$f->{personal}/common/upper/.setting", 'upper');
    my $first = apply_ok($f) or return;
    is(read_file("$f->{home}/.setting"), 'upper', 'home reads personal through generated links');
    ok(-l "$f->{home}/.setting", 'home entry is a link');
    my $generated = "$f->{state}/stow/$first->{generation}/.setting";
    ok(-l $generated && readlink($generated) !~ m{^/}, 'generated entry is a relative link');
    write_file("$f->{personal}/common/upper/.setting", 'edited live');
    is(read_file("$f->{home}/.setting"), 'edited live', 'source edit is immediately live');
    my $again = apply_ok($f) or return;
    ok($again->{noop} && $again->{generation} eq $first->{generation}, 'unchanged winner map is a link no-op');
    unlink "$f->{generic}/common/lower/.setting" or die $!;
    ok(apply_ok($f)->{noop}, 'shadow-only changes do not rebuild the winning generation');
    write_file("$f->{generic}/common/lower/.setting", 'lower');
    unlink "$f->{personal}/common/upper/.setting" or die $!;
    my $lower = apply_ok($f) or return;
    isnt($lower->{generation}, $first->{generation}, 'new immutable generation created');
    is(read_file("$f->{home}/.setting"), 'lower', 'upper removal reveals lower');
    ok(-d "$f->{state}/stow/$first->{generation}", 'old generation retained');
    rename "$f->{generic}", "$f->{generic}-gone" or die $!;
    rename "$f->{personal}", "$f->{personal}-gone" or die $!;
    my ($ok, $out, $err) = driver($f, 'delete');
    ok($ok, 'delete uses retained generation without source discovery') or diag($err);
    ok(!-e "$f->{home}/.setting" && !-l "$f->{home}/.setting", 'obsolete home link removed');
    ok(!receipt($f)->{generation}, 'empty applied receipt has no invented generation');
};

case_test 'replaced home entries and directory ancestors are preserved' => sub {
    for my $replacement (qw(file link same-file-link directory ancestor real-ancestor)) {
        my $f = fixture();
        write_file("$f->{generic}/common/pkg/.config/tool/config", 'source');
        apply_ok($f) or next;
        my $path = "$f->{home}/.config/tool/config";
        if ($replacement eq 'real-ancestor') {
            my $original = readlink $path;
            rename "$f->{home}/.config/tool", "$f->{home}/.config/tool-old" or die $!;
            make_path("$f->{home}/.config/tool");
            symlink $original, $path or die $!;
        } elsif ($replacement eq 'ancestor') {
            rename "$f->{home}/.config/tool", "$f->{home}/.config/tool-old" or die $!;
            make_path("$f->{base}/external");
            write_file("$f->{base}/external/config", 'external');
            symlink "$f->{base}/external", "$f->{home}/.config/tool" or die $!;
        } else {
            unlink $path or die $!;
            if ($replacement eq 'file') { write_file($path, 'human'); }
            elsif ($replacement eq 'link' || $replacement eq 'same-file-link') {
                symlink($replacement eq 'link' ? "$f->{base}/unrelated" : "$f->{generic}/common/pkg/.config/tool/config", $path) or die $!;
            }
            else { make_path($path); }
        }
        my ($ok, $out, $err) = driver($f, 'apply');
        ok(!$ok, "reapply rejects replacement: $replacement");
        like($err, qr/conflict|ancestor/i, 'ownership diagnostic');
        if ($replacement eq 'file') { is(read_file($path), 'human', 'human file preserved'); }
        elsif ($replacement eq 'ancestor') { is(read_file($path), 'external', 'external ancestor contents untouched'); }
        elsif ($replacement eq 'link') { is(readlink($path), "$f->{base}/unrelated", 'unrelated link preserved'); }
        elsif ($replacement eq 'same-file-link') { ok(-l $path && abs_path($path) eq abs_path("$f->{generic}/common/pkg/.config/tool/config"), 'equal dereferenced content does not imply ownership'); }
        elsif ($replacement eq 'real-ancestor') { ok(-l $path, 'replacement real ancestor/link remains untouched'); }
        else { ok(-d $path && !-l $path, 'human directory preserved'); }
    }
};

case_test 'failure injection, retained evidence and resume/restore' => sub {
    for my $failure (qw(build build-entry before-stow partial after-stow verification publication after-publication kill-after-stow)) {
        for my $action (qw(resume restore)) {
            my $f = fixture();
            write_file("$f->{generic}/common/pkg/.setting", 'old');
            write_file("$f->{generic}/hooks/post-stow.d/10-test", "#!/bin/sh\nprintf hook >> \"\$HOME/failure-hooks\"\n");
            chmod 0755, "$f->{generic}/hooks/post-stow.d/10-test";
            my $old = apply_ok($f) or next;
            unlink "$f->{home}/failure-hooks" or die $!;
            write_file("$f->{personal}/common/pkg/.setting", 'new');
            my ($ok, $out, $err) = driver($f, 'apply', $failure);
            ok(!$ok, "$failure is reported as failure");
            ok(!-e "$f->{home}/failure-hooks", 'failed apply never runs hooks');
            ok(-f "$f->{state}/pending.json", 'pending journal retained');
            my $pending = Dotfiletracker::TargetGuard::read_json("$f->{state}/pending.json");
            ok($pending->{old}{generation} eq $old->{generation}, 'old generation recorded');
            my ($blocked, undef, $diagnostic) = driver($f, 'apply');
            ok(!$blocked, 'new apply blocked by pending operation');
            like($diagnostic, qr/Unfinished stack operation/, 'recovery required, no automatic retry');
            my $inspection = recover_ok($f, 'inspect');
            like($inspection, qr/"phase":/, 'inspect returns actual journal phase');
            recover_ok($f, $action);
            ok(!-e "$f->{home}/failure-hooks", 'recovery never runs hooks');
            is(read_file("$f->{home}/.setting"), $action eq 'resume' ? 'new' : 'old', 'recovery reconciles requested generation');
            ok(!-e "$f->{state}/pending.json", 'completed journal archived');
            ok(-d "$f->{state}/operations/$pending->{id}", 'operation logs retained');
        }
    }
};

case_test 'shared guard blocks every legacy writer and alternate state directory' => sub {
    for my $pending (0, 1) {
        my $f = fixture();
        write_file("$f->{generic}/common/pkg/.setting", 'stack');
        apply_ok($f) or next;
        if ($pending) {
            write_file("$f->{personal}/common/pkg/.setting", 'pending');
            driver($f, 'apply', 'after-stow');
        }
        write_file("$f->{base}/rewrite.sh", "function keep { :; }\n");
        write_file("$f->{base}/aliases.sh", "alias keep='printf keep'\n");
        make_path("$f->{base}/legacy/parts/application", "$f->{base}/legacy/common/pkg");
        write_file("$f->{base}/legacy/common/pkg/.legacy", 'legacy');
        write_file("$f->{home}/completion-input", "#compdef demo\n");
        $f->{env}{XDG_STATE_HOME} = "$f->{base}/other-state";
        my @commands = (
            (map { ['bash', "$repo/envmaker.sh", '--dotfiles-dir', "$f->{base}/legacy", '--yes', 'execstow', $_] } qw(stow restow delete)),
            ['bash', "$repo/envmaker.sh", '--dotfiles-dir', "$f->{base}/legacy", '--yes', 'del'],
            [$perl, "$repo/tests/overlay_state_driver.pl", 'completion', '--dotfiles-dir', "$f->{base}/legacy", '--no-stow', 'demo'],
            ['bash', "$repo/util/remove_function_keyword.sh", "$f->{base}/rewrite.sh"],
            ['bash', "$repo/util/convert_aliases_to_functions.sh", "$f->{base}/aliases.sh"],
            ['bash', "$repo/envmaker.sh", 'execstow', 'restow'],
            ['bash', "$repo/envmaker.sh", 'apply'], ['bash', "$repo/envmaker.sh", 'migrate'],
            ['bash', "$repo/envmaker.sh", 'recover', 'restore']);
        for my $command (@commands) {
            my ($ok, $out, $err) = run($f, @$command);
            ok(!$ok, 'writer cannot bypass active/pending ownership with another XDG state');
            if ($command->[1] =~ m{/(?:util/|tests/overlay_state_driver)}) {
                like($err, qr/Stack owns this target|Target is owned by a different stack state/, 'utility refusal is the common ownership guard, not missing stdin/input');
            }
        }
        is(read_file("$f->{base}/rewrite.sh"), "function keep { :; }\n", 'explicit function file unchanged');
        is(read_file("$f->{base}/aliases.sh"), "alias keep='printf keep'\n", 'explicit alias file unchanged');
        ok(!-e "$f->{base}/legacy/parts/application/demo", 'completion destination untouched');
    }
};

case_test 'preview and source/control protections make no persistent plan changes' => sub {
    my $f = fixture();
    write_file("$f->{generic}/common/pkg/.setting", 'source');
    my ($ok, $out, $err) = driver($f, 'preview');
    ok($ok, 'overlay preview succeeds') or diag($err);
    my $preview = JSON::PP->new->utf8->decode($out);
    ok(!$preview->{stow_simulation}, 'preview does not claim a real Stow simulation');
    ok(!-e $f->{state} && !-e "$f->{home}/.dotfiletracker-lock" && !-e "$f->{home}/.setting", 'preview creates no lock, state, generation or home link');
    for my $target ('.dotfiletracker-lock', '.dotfiletracker-owner.json', '.config/dotfiletracker/config', '.local/state/dotfiletracker/entry') {
        my $f = fixture();
        write_file("$f->{generic}/common/pkg/$target", 'source');
        my ($ok, undef, $err) = driver($f, 'apply');
        ok(!$ok, 'control path target rejected');
        like($err, qr/reserved|control path/, 'control conflict is explicit');
        ok(!-e $f->{state}, 'validation happens before persistent state creation');
    }
    my $nested = fixture();
    write_file("$nested->{generic}/common/pkg/.setting", 'source');
    $nested->{env}{XDG_STATE_HOME} = "$nested->{generic}/common/pkg/state";
    my ($valid, undef, $diagnostic) = driver($nested, 'apply');
    ok(!$valid, 'state overlap with source rejected');
    like($diagnostic, qr/Source overlaps generated state/, 'overlap diagnostic');
    ok(!-e "$nested->{generic}/common/pkg/state", 'rejected state path does not mutate source checkout');
    my $home_source = fixture();
    make_path("$home_source->{home}/parts", "$home_source->{home}/common/pkg");
    write_file("$home_source->{home}/common/pkg/.setting", 'source');
    write_file("$home_source->{home}/.config/dotfiletracker/config", "source.home=$home_source->{home}\n");
    my ($home_ok, undef, $home_err) = driver($home_source, 'apply');
    ok(!$home_ok && $home_err =~ /overlaps a registered source/, 'source containing HOME is rejected before guard creation');
    ok(!-e "$home_source->{home}/.dotfiletracker-lock" && !-e "$home_source->{home}/.dotfiletracker-owner.json", 'guard metadata never lands in a registered source');
    my $roles = fixture();
    local %ENV = %{$roles->{env}};
    my $readonly = Dotfiletracker::OverlayState->new(mode => 'inspect');
    eval { $readonly->delete_applied; };
    like($@, qr/guard role/, 'read-only API object cannot delete under a shared lock');
    eval { $readonly->recover('restore'); };
    like($@, qr/guard role/, 'read-only API object cannot restore under a shared lock');
    ok(!-e "$roles->{home}/.dotfiletracker-lock", 'role refusal occurs before lock creation');
};

case_test 'real Stow failures retain logs and recovery preserves unowned replacements' => sub {
    my $f = fixture();
    write_file("$f->{generic}/common/pkg/.setting", 'source');
    my ($ok, undef, $err) = driver($f, 'apply', 'stow-conflict');
    ok(!$ok, 'real Stow conflict fails the operation');
    like($err, qr/Stow transition failed/, 'failure points to retained logs');
    my $pending = Dotfiletracker::TargetGuard::read_json("$f->{state}/pending.json");
    is($pending->{phase}, 'stow-failed', 'failed execution is not recorded as a success');
    ok($pending->{runs}[-1]{exit_status}, 'actual nonzero subprocess status recorded');
    ok($pending->{runs}[-1]{pid} && -f $pending->{runs}[-1]{stderr}, 'PID and separate stderr log retained');
    for my $action (qw(resume restore)) {
        my ($recovered, undef, $diagnostic) = run($f, 'bash', "$repo/envmaker.sh", 'recover', $action);
        ok(!$recovered, 'recovery refuses unowned replacement');
        is(read_file("$f->{home}/.setting"), 'human replacement', 'human contents preserved');
    }
    unlink "$f->{home}/.setting" or die $!;
    recover_ok($f, 'restore');
    ok(!-e "$f->{home}/.setting", 'first-apply rollback restores empty ownership');
};

case_test 'durable intent closes the claim/pending publication gap' => sub {
    for my $action (qw(resume restore)) {
        my $f = fixture();
        write_file("$f->{generic}/common/pkg/.setting", 'source');
        my ($ok) = driver($f, 'apply', 'journal');
        ok(!$ok && !-e "$f->{state}/pending.json", 'injected crash before pending publication');
        my $owner = Dotfiletracker::TargetGuard::read_json("$f->{home}/.dotfiletracker-owner.json");
        ok($owner->{intent}, 'target ownership records durable operation intent');
        my ($fresh, undef, $err) = driver($f, 'apply');
        ok(!$fresh && $err =~ /Unfinished/, 'missing pending file does not permit fresh adoption');
        recover_ok($f, 'inspect');
        recover_ok($f, $action);
        ok($action eq 'resume' ? -l "$f->{home}/.setting" : !-e "$f->{home}/.setting", 'intent-based recovery reaches desired state');
    }
};

case_test 'recovery dry-run refuses mutation and empty effective apply removes obsolete links' => sub {
    my $f = fixture();
    write_file("$f->{generic}/common/pkg/.setting", 'old');
    apply_ok($f) or return;
    write_file("$f->{personal}/common/pkg/.setting", 'new');
    driver($f, 'apply', 'after-stow');
    my $before = read_file("$f->{state}/pending.json");
    my $text = readlink "$f->{home}/.setting";
    my ($ok, undef, $err) = run($f, 'bash', "$repo/envmaker.sh", '--dry-run', 'recover', 'resume');
    ok(!$ok && $err =~ /use recover inspect/, 'recovery cannot silently ignore dry-run');
    is(read_file("$f->{state}/pending.json"), $before, 'dry-run refusal leaves journal unchanged');
    is(readlink("$f->{home}/.setting"), $text, 'dry-run refusal leaves target unchanged');
    recover_ok($f, 'restore');
    unlink "$f->{generic}/common/pkg/.setting" or die $!;
    unlink "$f->{personal}/common/pkg/.setting" or die $!;
    my $empty = apply_ok($f) or return;
    ok(!$empty->{generation} && !receipt($f)->{generation}, 'empty plan has no empty owner generation');
    ok(!-l "$f->{home}/.setting", 'empty plan removes previously owned link');
};

case_test 'relative Unicode/link entries and discovery under the target lock' => sub {
    my $f = fixture();
    my $name = "file ü:=x\nnext";
    write_file("$f->{generic}/common/pkg/$name", 'live');
    write_file("$f->{generic}/common/pkg/.stow-local-ignore", "# select default-ignored files too\n");
    write_file("$f->{generic}/common/pkg/.gitignore", 'selected');
    chmod 0755, "$f->{generic}/common/pkg/$name";
    symlink $name, "$f->{generic}/common/pkg/alias" or die $!;
    write_file("$f->{generic}/parts/feature/pkg/.rule", 'selected');
    $f->{env}{GUARD_PROBE} = "$repo/bin/mutation_guard.pl";
    write_file("$f->{generic}/rules/feature", '#!/bin/sh' . "\n" .
        'if perl "$GUARD_PROBE" run legacy -- true 2>/dev/null; then exit 1; fi' . "\n" .
        'printf held >> "$HOME/rule-locked"' . "\n");
    chmod 0755, "$f->{generic}/rules/feature";
    my $applied = apply_ok($f) or return;
    is(read_file("$f->{home}/$name"), 'live', 'Unicode/newline target resolves');
    is(read_file("$f->{home}/alias"), 'live', 'source regular-file link stays in live chain');
    ok(-x "$f->{home}/$name", 'executable mode stays live');
    is(read_file("$f->{home}/.gitignore"), 'selected', 'generation metadata prevents a second default ignore pass');
    is(read_file("$f->{home}/rule-locked"), 'held', 'discovery runs exactly once while target lock is held');
    ok(-l "$f->{home}/.rule", 'source-local selected part applied');
};

case_test 'generation inventory tampering and source-independent restore' => sub {
    my $f = fixture();
    write_file("$f->{generic}/common/pkg/.setting", 'source');
    my $applied = apply_ok($f) or return;
    symlink "$f->{generic}/common/pkg/.setting", "$f->{state}/stow/$applied->{generation}/.extra" or die $!;
    my ($ok, undef, $err) = driver($f, 'apply');
    ok(!$ok && $err =~ /Unrecorded generated entry/, 'extra generated files cannot enlarge apply inventory');
    ok(!-e "$f->{home}/.extra", 'unrecorded home entry was never installed');
    my $other = fixture();
    write_file("$other->{generic}/common/pkg/.setting", 'old');
    apply_ok($other) or return;
    write_file("$other->{personal}/common/pkg/.setting", 'new');
    driver($other, 'apply', 'after-stow');
    rename $other->{generic}, "$other->{generic}-gone" or die $!;
    rename $other->{personal}, "$other->{personal}-gone" or die $!;
    recover_ok($other, 'restore');
    ok(-l "$other->{home}/.setting", 'recorded old link restored even when sources are unavailable');
};

case_test 'legacy allowed entrypoints and inherited previews retain exclusive locks' => sub {
    my $f = fixture();
    write_file("$f->{generic}/common/pkg/.legacy", 'source');
    for my $action (qw(stow restow delete stow)) {
        my ($ok, undef, $err) = run($f, 'bash', "$repo/envmaker.sh", '--dotfiles-dir', $f->{generic}, '--yes', 'execstow', $action);
        ok($ok, "unowned legacy $action still succeeds") or diag($err);
    }
    my ($preview, $preview_out, $preview_err) = run($f, 'bash', "$repo/envmaker.sh", '--dotfiles-dir', $f->{generic}, '--yes', '--dry-run', 'del');
    ok($preview && -l "$f->{home}/.legacy", 'legacy del dry-run cannot mutate through a read-only guard');
    like($preview_out, qr/no links were changed/, 'legacy deletion preview states its boundary');
    my ($deleted, undef, $err) = run($f, 'bash', "$repo/envmaker.sh", '--dotfiles-dir', $f->{generic}, '--yes', 'del');
    ok($deleted && !-l "$f->{home}/.legacy", 'legacy del remains functional with guard');
    my ($exclusive) = run($f, $perl, "$repo/bin/mutation_guard.pl", 'run', 'legacy', '--',
        $perl, "$repo/tests/overlay_state_driver.pl", 'nested-preview');
    ok($exclusive, 'nested preview verification cannot downgrade the parent exclusive lock');
};

case_test 'delete recovery and recorded live subprocess refusal' => sub {
    for my $action (qw(resume restore)) {
        my $f = fixture();
        write_file("$f->{generic}/common/pkg/.setting", 'source');
        apply_ok($f) or next;
        rename $f->{generic}, "$f->{generic}-gone" or die $!;
        rename $f->{personal}, "$f->{personal}-gone" or die $!;
        my ($ok) = driver($f, 'delete', 'after-stow');
        ok(!$ok, 'interrupted source-independent delete retains recovery');
        recover_ok($f, $action);
        ok($action eq 'resume' ? !-l "$f->{home}/.setting" : -l "$f->{home}/.setting", 'delete recovery reaches requested owned link state');
    }
    my $f = fixture();
    write_file("$f->{generic}/common/pkg/.setting", 'old');
    apply_ok($f) or return;
    write_file("$f->{personal}/common/pkg/.setting", 'new');
    driver($f, 'apply', 'after-stow');
    my $journal = Dotfiletracker::TargetGuard::read_json("$f->{state}/pending.json");
    $journal->{runs}[-1]{pid} = $$;
    $journal->{runs}[-1]{exit_status} = undef;
    Dotfiletracker::OverlayState::write_json("$f->{state}/pending.json", $journal);
    my $before = readlink "$f->{home}/.setting";
    my ($ok, undef, $err) = run($f, 'bash', "$repo/envmaker.sh", 'recover', 'resume');
    ok(!$ok && $err =~ /Recorded Stow process is still live/, 'recovery verifies recorded process and never forces a live PID');
    is(readlink("$f->{home}/.setting"), $before, 'live-PID refusal leaves home links unchanged');
    $journal->{runs}[-1]{exit_status} = 0;
    Dotfiletracker::OverlayState::write_json("$f->{state}/pending.json", $journal);
    recover_ok($f, 'restore');
};

case_test 'forged inherited descriptors cannot bypass the shared guard' => sub {
    my $f = fixture();
    write_file("$f->{base}/rewrite.sh", "function keep { :; }\n");
    $f->{env}{DFT_GUARD_FD} = 999;
    my ($ok, undef, $err) = run($f, 'bash', "$repo/util/remove_function_keyword.sh", "$f->{base}/rewrite.sh");
    ok(!$ok && $err =~ /Invalid inherited target lock descriptor/, 'an environment flag without a verified descriptor is refused');
    is(read_file("$f->{base}/rewrite.sh"), "function keep { :; }\n", 'forged guard leaves explicit target unchanged');
    delete $f->{env}{DFT_GUARD_FD};
    write_file("$f->{generic}/common/pkg/.setting", 'source');
    apply_ok($f) or return;
    chmod 0777, $f->{state} or die $!;
    my ($private, undef, $diagnostic) = driver($f, 'apply');
    ok(!$private && $diagnostic =~ /not private to its owner/, 'active state permission changes fail closed');
    chmod 0700, $f->{state} or die $!;
    my $special = fixture();
    POSIX::mkfifo("$special->{home}/.dotfiletracker-lock", 0600) == 0 or die $!;
    local %ENV = %{$special->{env}};
    eval { Dotfiletracker::TargetGuard->new(mode => 'inspect'); };
    like($@, qr/regular file/, 'special lock files are refused before a blocking open');
};

case_test 'migration previews, direct and folded links, failures and rollback' => sub {
    for my $folded (0, 1) {
        for my $failure ('', qw(journal build build-entry migration-unlink before-stow partial after-stow verification publication after-publication)) {
            for my $action (qw(resume restore)) {
                next if !$failure && $action eq 'restore';
                my $f = fixture();
                write_file("$f->{generic}/common/pkg/.tool/config", 'generic');
                write_file("$f->{personal}/common/other/.tool/config", 'personal');
                write_file("$f->{generic}/common/pkg/.direct", 'direct');
                my ($stowed, undef, $stow_error) = run($f, "/opt/stow-$version/bin/stow", '--dir', "$f->{generic}/common", '--target', $f->{home},
                    ($folded ? () : ('--no-folding')), 'pkg');
                ok($stowed, 'real legacy Stow fixture') or diag($stow_error);
                my $old_path = $folded ? '.tool' : '.tool/config';
                my $old_text = readlink "$f->{home}/$old_path";
                my ($preview, $out, $err) = driver($f, 'migration-preview');
                ok($preview, 'migration preview accepts exact direct/folded links') or diag($err);
                ok(!-e $f->{state} && !-e "$f->{home}/.dotfiletracker-lock", 'preview creates no persistent metadata');
                is(readlink("$f->{home}/$old_path"), $old_text, 'preview leaves legacy link unchanged');
                my ($ok, $result, $error) = driver($f, 'migrate', $failure);
                if ($failure) {
                    ok(!$ok, "$failure migration failure is nonzero") or diag($result);
                    recover_ok($f, $action);
                    if ($action eq 'restore') {
                        is(readlink("$f->{home}/$old_path"), $old_text, 'rollback restores exact legacy link text');
                        is(read_file("$f->{home}/.tool/config"), 'generic', 'rollback restores legacy owner');
                    } else { is(read_file("$f->{home}/.tool/config"), 'personal', 'resume selects overlay winner'); }
                } else {
                    ok($ok, 'migration applies') or diag($error, $result);
                    is(read_file("$f->{home}/.tool/config"), 'personal', 'migration chooses personal per target');
                    ok(-d "$f->{home}/.tool" && !-l "$f->{home}/.tool", 'folded directory becomes real');
                }
                is(read_file("$f->{generic}/common/pkg/.tool/config"), 'generic', 'generic bytes preserved');
                is(read_file("$f->{personal}/common/other/.tool/config"), 'personal', 'personal bytes preserved');
            }
        }
    }
};

case_test 'migration refuses unrelated links and structural transitions without source changes' => sub {
    for my $kind (qw(unrelated absolute ignored structural replacement ancestor)) {
        my $f = fixture();
        write_file("$f->{generic}/common/pkg/.tool/config", 'generic');
        if ($kind eq 'structural') {
            write_file("$f->{generic}/common/pkg/.old", 'old');
            symlink File::Spec->abs2rel("$f->{generic}/common/pkg/.old", $f->{home}), "$f->{home}/.tool" or die $!;
        } elsif ($kind eq 'ignored') {
            write_file("$f->{generic}/common/pkg/.tool/ignored~", 'keep');
            symlink File::Spec->abs2rel("$f->{generic}/common/pkg/.tool", $f->{home}), "$f->{home}/.tool" or die $!;
        } elsif ($kind eq 'ancestor') {
            make_path("$f->{base}/elsewhere");
            symlink "$f->{base}/elsewhere", "$f->{home}/.tool" or die $!;
        } else {
            make_path("$f->{home}/.tool");
            if ($kind eq 'replacement') { write_file("$f->{home}/.tool/config", 'human'); }
            else { symlink($kind eq 'absolute' ? "$f->{generic}/common/pkg/.tool/config" : "$f->{base}/unrelated", "$f->{home}/.tool/config") or die $!; }
        }
        my $path = -l "$f->{home}/.tool" ? "$f->{home}/.tool" : "$f->{home}/.tool/config";
        my $before = -l $path ? readlink($path) : read_file($path);
        for my $action (qw(migration-preview migrate)) {
            my ($ok, undef, $err) = driver($f, $action);
            ok(!$ok, "$kind refused by $action");
            like($err, qr/unrelated|unselected|replacement|structure/, 'explicit refusal diagnostic');
            is(-l $path ? readlink($path) : read_file($path), $before, 'replacement/legacy link remains unchanged');
            ok(!-e $f->{state}, 'refusal creates no generation/journal');
        }
        is(read_file("$f->{generic}/common/pkg/.tool/config"), 'generic', 'source bytes unchanged');
    }
};

case_test 'source-local hook order warnings and generation inspection without sources' => sub {
    my $f = fixture();
    write_file("$f->{generic}/common/pkg/.nested/config", 'generic');
    for my $source (qw(generic personal)) {
        for my $name (qw(20-check 10-check)) {
            write_file("$f->{$source}/hooks/post-stow.d/$name", '#!/bin/sh' . "\n" .
                'printf "%s:%s:%s:%s\\n" "$DOTFILETRACKER_SOURCE_ID" "${0##*/}" "$1" "$DOTFILES_DIR" >> "$HOME/hooks"' . "\n" .
                ($name eq '10-check' ? 'exit 7' : 'exit 0') . "\n");
            chmod 0755, "$f->{$source}/hooks/post-stow.d/$name";
        }
    }
    my ($preview) = driver($f, 'preview');
    ok($preview && !-e "$f->{home}/hooks", 'preview skips hooks');
    my ($ok, $out, $err) = driver($f, 'apply');
    ok($ok && $err =~ /Warning: post-stow hook generic:10-check/, 'hook failures warn after successful application');
    my @hooks = split /\n/, read_file("$f->{home}/hooks");
    is_deeply(\@hooks, [map { my $s = $_; map { "$s:$_:restow:$f->{$s}" } qw(10-check 20-check) } qw(generic personal)], 'source order then lexical order; duplicate basenames both run');
    rename $f->{generic}, "$f->{generic}-gone" or die $!;
    rename $f->{personal}, "$f->{personal}-gone" or die $!;
    my ($listed, $listing, $error) = driver($f, 'ls');
    ok($listed, 'inspection does not rediscover missing sources') or diag($error);
    my $inspection = JSON::PP->new->utf8->decode($listing);
    ok($inspection->{targets}[0]{owned}, 'literal generation ownership is reported even for broken source chain');
    is($inspection->{targets}[0]{owner}{source_id}, 'generic', 'source qualified owner');
    my ($delete_preview) = driver($f, 'delete-preview');
    ok($delete_preview && -l "$f->{home}/.nested/config", 'delete preview preserves recorded deep link');
    my ($deleted) = driver($f, 'delete');
    ok($deleted && !-l "$f->{home}/.nested/config", 'delete uses generation inventory without sources');
    is_deeply([split /\n/, read_file("$f->{home}/hooks")], \@hooks, 'delete never invokes hooks');
};

case_test 'migration preserves Git worktrees and structural refusal has a deletion recovery path' => sub {
    for my $failure ('', 'after-stow') {
        my $f = fixture();
        write_file("$f->{generic}/common/pkg/.setting", 'generic');
        write_file("$f->{generic}/parts/.keep", '');
        for my $source (qw(generic personal)) {
            write_file("$f->{$source}/common/pkg/.setting", $source);
            my ($init) = run($f, 'git', '-C', $f->{$source}, 'init', '-q');
            ok($init, 'local source repository initialized');
            run($f, 'git', '-C', $f->{$source}, 'add', '.');
            my ($commit) = run($f, 'git', '-C', $f->{$source}, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'fixture');
            ok($commit, 'fixture committed without external hooks');
        }
        my ($stowed) = run($f, "/opt/stow-$version/bin/stow", '--dir', "$f->{generic}/common", '--target', $f->{home}, '--no-folding', 'pkg');
        ok($stowed, 'direct Stow fixture');
        my %before;
        for my $source (qw(generic personal)) { (undef, $before{$source}) = run($f, 'git', '-C', $f->{$source}, 'status', '--porcelain'); }
        my ($ok) = driver($f, 'migrate', $failure);
        ok($failure ? !$ok : $ok, 'migration result matches requested failure');
        recover_ok($f, 'restore') if $failure;
        for my $source (qw(generic personal)) {
            my ($status, $out) = run($f, 'git', '-C', $f->{$source}, 'status', '--porcelain');
            ok($status && $out eq $before{$source}, 'source Git status unchanged');
            is(read_file("$f->{$source}/common/pkg/.setting"), $source, 'source bytes unchanged');
        }
    }
    my $f = fixture();
    write_file("$f->{generic}/common/pkg/.shape", 'old file');
    apply_ok($f) or return;
    unlink "$f->{generic}/common/pkg/.shape" or die $!;
    write_file("$f->{generic}/common/pkg/.shape/config", 'new child');
    my $old_link = readlink "$f->{home}/.shape";
    my ($applied, undef, $error) = driver($f, 'apply');
    ok(!$applied && $error =~ /ancestor/, 'managed file to directory ancestor is explicitly refused');
    is(readlink("$f->{home}/.shape"), $old_link, 'refusal leaves original owned home link');
    my ($deleted) = driver($f, 'delete');
    ok($deleted, 'recorded-generation delete does not need the old source type');
    apply_ok($f);
    is(read_file("$f->{home}/.shape/config"), 'new child', 'explicit delete then apply is the safe structural recovery path');
    my $missing = fixture();
    write_file("$missing->{generic}/common/pkg/.tool/config", 'generic');
    write_file("$missing->{personal}/common/pkg/.tool/config", 'personal');
    run($missing, "/opt/stow-$version/bin/stow", '--dir', "$missing->{generic}/common", '--target', $missing->{home}, 'pkg');
    my $fold_text = readlink "$missing->{home}/.tool";
    my ($failed) = driver($missing, 'migrate', 'after-stow');
    ok(!$failed, 'migration interrupted after actual Stow');
    rename $missing->{generic}, "$missing->{generic}-gone" or die $!;
    rename $missing->{personal}, "$missing->{personal}-gone" or die $!;
    recover_ok($missing, 'restore');
    is(readlink("$missing->{home}/.tool"), $fold_text, 'migration restores exact folded link with absent source trees');
};

case_test 'public stack apply migration inspection deletion and utility destinations' => sub {
    for my $first (qw(stow restow migrate)) {
        my $f = fixture();
        write_file("$f->{generic}/common/pkg/.setting", 'generic');
        write_file("$f->{personal}/common/other/.setting", 'personal');
        if ($first eq 'migrate') {
            my ($ok) = run($f, "/opt/stow-$version/bin/stow", '--dir', "$f->{generic}/common", '--target', $f->{home}, '--no-folding', 'pkg');
            ok($ok, 'direct links for public migration');
        }
        my @action = $first eq 'migrate' ? ('migrate', '--from', 'generic') : ('execstow', $first);
        my ($preview, $out, $err) = run($f, 'bash', "$repo/envmaker.sh", '--yes', '--dry-run', @action);
        ok($preview, 'public operation preview') or diag($err, $out);
        my $report = eval { JSON::PP->new->utf8->decode($out) };
        ok($report && !$report->{stow_simulation}, 'preview JSON and explicit simulation boundary');
        ok(!-e $f->{state} && !-e "$f->{home}/.dotfiletracker-lock", 'public preview leaves metadata absent');
        my ($applied, $json, $error) = run($f, 'bash', "$repo/envmaker.sh", '--verbose', '--yes', @action);
        ok($applied, "public $first succeeds") or diag($error, $json);
        like($error, qr/Stow transition:/, 'verbose mode reports controlled transition commands on stderr');
        is(read_file("$f->{home}/.setting"), 'personal', 'public frontend selects priority winner');
        my ($noop, $noop_json) = run($f, 'bash', "$repo/envmaker.sh", 'execstow', 'restow');
        ok($noop && JSON::PP->new->utf8->decode($noop_json)->{noop}, 'public restow reconciles without confirmation and detects no-op');
        rename $f->{generic}, "$f->{generic}-gone" or die $!;
        rename $f->{personal}, "$f->{personal}-gone" or die $!;
        my ($listed, $listing) = run($f, 'bash', "$repo/envmaker.sh", 'ls');
        ok($listed && JSON::PP->new->utf8->decode($listing)->{targets}[0]{owned}, 'public ls reports generation with absent source roots');
        my @delete = $first eq 'restow' ? ('del') : ('execstow', 'delete');
        my ($preview_delete) = run($f, 'bash', "$repo/envmaker.sh", '--yes', '--dry-run', @delete);
        ok($preview_delete && -l "$f->{home}/.setting", 'public source-independent delete preview');
        my ($delete) = run($f, 'bash', "$repo/envmaker.sh", '--yes', @delete);
        ok($delete && !-l "$f->{home}/.setting", 'both public delete entrypoints use retained inventory');
        rename "$f->{generic}-gone", $f->{generic} or die $!;
        rename "$f->{personal}-gone", $f->{personal} or die $!;
        write_file("$f->{home}/.config/dotfiletracker/config", "dotfiles_dir=$f->{generic}\n");
        my ($legacy) = run($f, 'bash', "$repo/envmaker.sh", '--yes', 'execstow', 'stow');
        my ($legacy_ls, $legacy_listing) = run($f, 'bash', "$repo/envmaker.sh", 'ls');
        ok($legacy && $legacy_ls && $legacy_listing =~ /\.setting/, 'released stack ownership does not hide later legacy inspection');
    }
    for my $utility (qw(remove_function_keyword convert_aliases_to_functions)) {
        for my $destination (qw(generic personal explicit)) {
            my $f = fixture();
            my $bytes = $utility eq 'remove_function_keyword' ? "function demo { :; }\n" : "alias demo='printf demo'\n";
            for my $source (qw(generic personal)) { write_file("$f->{$source}/common/pkg/functions.sh", $bytes); }
            apply_ok($f) or next;
            my $selected = $destination eq 'explicit' ? 'personal' : $destination;
            my @options = $destination eq 'explicit' ? ("$f->{personal}/common/pkg/functions.sh") : ('--source', $destination);
            my ($preview) = run($f, 'bash', "$repo/util/$utility.sh", '--dry-run', @options);
            ok($preview, 'utility preview uses explicit destination');
            is(read_file("$f->{$selected}/common/pkg/functions.sh"), $bytes, 'preview leaves selected source unchanged');
            my ($ok, $out, $err) = run($f, 'bash', "$repo/util/$utility.sh", @options);
            ok($ok, "$utility writes to $destination under active stack ownership") or diag($err, $out);
            isnt(read_file("$f->{$selected}/common/pkg/functions.sh"), $bytes, 'selected source rewritten');
            my $other = $selected eq 'generic' ? 'personal' : 'generic';
            is(read_file("$f->{$other}/common/pkg/functions.sh"), $bytes, 'other source unchanged');
            my ($control, undef, $error) = run($f, 'bash', "$repo/util/$utility.sh", "$f->{home}/functions.sh");
            ok(!$control && $error =~ /managed HOME\/control/, 'utility refuses managed home link as explicit destination');
            my ($unnamed, undef, $diagnostic) = run($f, 'bash', "$repo/util/$utility.sh");
            ok(!$unnamed && $diagnostic =~ /require --source/, 'stack utility never chooses an implicit source');
        }
    }
    my $mutating = fixture();
    write_file("$mutating->{generic}/parts/mutating/pkg/.rule", 'rule');
    write_file("$mutating->{generic}/rules/mutating", '#!/bin/sh' . "\nprintf rule >> \"\$HOME/rule-preview-effect\"\n");
    chmod 0755, "$mutating->{generic}/rules/mutating";
    my ($preview) = run($mutating, 'bash', "$repo/envmaker.sh", '--dry-run', 'execstow', 'restow');
    ok($preview, 'public preview runs trusted discovery');
    is(read_file("$mutating->{home}/rule-preview-effect"), 'rule', 'trusted mutating rule runs exactly once during preview');
    ok(!-e $mutating->{state} && !-e "$mutating->{home}/.dotfiletracker-lock" && !-l "$mutating->{home}/.rule", 'wrapper still creates no persistent state or home link');
};

case_test 'fork application preserves generic status and whole-file inheritance' => sub {
    my $f = fixture();
    write_file("$f->{generic}/common/original/.setting", 'base');
    write_file("$f->{generic}/parts/.keep", '');
    run($f, 'git', '-C', $f->{generic}, 'init', '-q');
    run($f, 'git', '-C', $f->{generic}, 'add', '.');
    my ($committed) = run($f, 'git', '-C', $f->{generic}, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
        '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'base');
    ok($committed, 'generic fixture committed');
    rmdir "$f->{personal}/parts" or die $!;
    rmdir $f->{personal} or die $!;
    my ($cloned) = run($f, 'git', 'clone', '-q', '--no-hardlinks', $f->{generic}, $f->{personal});
    ok($cloned, 'personal is a local Git clone');
    rename "$f->{personal}/common/original", "$f->{personal}/common/different-package" or die $!;
    write_file("$f->{personal}/common/different-package/.setting", 'personal');
    for my $lower ('base', 'upstream change', 'personal') {
        write_file("$f->{generic}/common/original/.setting", $lower);
        my (undef, $before) = run($f, 'git', '-C', $f->{generic}, 'status', '--porcelain');
        apply_ok($f) or next;
        is(read_file("$f->{home}/.setting"), 'personal', 'personal fork copy owns target regardless of generic change/equal bytes');
        my (undef, $after) = run($f, 'git', '-C', $f->{generic}, 'status', '--porcelain');
        is($after, $before, 'apply preserves generic Git status');
        is(read_file("$f->{generic}/common/original/.setting"), $lower, 'apply preserves generic bytes');
        is(Dotfiletracker::TargetGuard::read_json("$f->{state}/manifests/" . receipt($f)->{generation} . '.json')->{targets}[0]{owner}{source_id}, 'personal', 'equal bytes do not change owner');
    }
    unlink "$f->{personal}/common/different-package/.setting" or die $!;
    apply_ok($f);
    is(read_file("$f->{home}/.setting"), 'personal', 'removal reveals current generic bytes');
    unlink "$f->{generic}/common/original/.setting" or die $!;
    apply_ok($f);
    ok(!-l "$f->{home}/.setting", 'removal from both unlinks obsolete owned target');
};

case_test 'all utility entrypoints reject pending operations and replaced home entries' => sub {
    for my $kind (qw(pending replacement)) {
        my $f = fixture();
        write_file("$f->{generic}/common/pkg/.setting", 'generic');
        write_file("$f->{personal}/common/pkg/functions.sh", "function keep { :; }\n");
        make_path("$f->{personal}/parts/application");
        write_file("$f->{home}/completion-input", "#compdef printf\n");
        apply_ok($f) or next;
        if ($kind eq 'pending') {
            write_file("$f->{personal}/common/pkg/.setting", 'personal');
            driver($f, 'apply', 'after-stow');
        } else {
            unlink "$f->{home}/.setting" or die $!;
            write_file("$f->{home}/.setting", 'human');
        }
        my @commands = (
            [$perl, "$repo/tests/overlay_state_driver.pl", 'completion', '--source', 'personal', '--no-stow', 'printf'],
            map { ['bash', "$repo/util/$_.sh", '--source', 'personal'] } qw(remove_function_keyword convert_aliases_to_functions));
        for my $command (@commands) {
            my ($ok, undef, $err) = run($f, @$command);
            ok(!$ok && $err =~ /Unfinished stack operation|preserving replacement/, "$kind blocks every utility before source writes") or diag($err);
        }
        is(read_file("$f->{personal}/common/pkg/functions.sh"), "function keep { :; }\n", 'rewrite source preserved');
        ok(!-e "$f->{personal}/parts/application/printf", 'completion source untouched');
    }
};

case_test 'every command entry reuses inherited EX and rejects missing or forged descriptors' => sub {
    my @entries = qw(detect ls del delete-preview exec-delete stow restow apply-preview migrate migrate-preview
        recover-inspect recover-resume recover-restore completion remove-keyword convert-aliases legacy-del legacy-delete
        legacy-verify legacy-preview-verify writer-verify writer-preview-verify);
    @entries = reverse @entries if $ENV{DFT_TEST_REVERSE};
    for my $entry (@entries) {
        for my $inherit (qw(valid missing forged)) {
            my $f = fixture();
            write_file("$f->{generic}/common/pkg/.setting", 'generic');
            write_file("$f->{personal}/common/pkg/functions.sh", "function keep { :; }\n");
            make_path("$f->{personal}/parts/application");
            write_file("$f->{home}/completion-input", "#compdef printf\n");
            my $legacy = $entry =~ /^(?:legacy-|migrate)/;
            if ($legacy) {
                my ($ok) = run($f, "/opt/stow-$version/bin/stow", '--dir', "$f->{generic}/common", '--target', $f->{home}, '--no-folding', 'pkg');
                ok($ok, 'legacy source links prepared');
            } else { apply_ok($f) or next; }
            if ($entry =~ /^recover-/) {
                write_file("$f->{personal}/common/pkg/.setting", 'personal');
                my ($failed) = driver($f, 'apply', 'after-stow');
                ok(!$failed, 'pending recovery operation prepared');
            }
            write_file("$f->{home}/.config/dotfiletracker/config", "dotfiles_dir=$f->{generic}\n") if $entry =~ /^legacy-/;
            my %commands = (
                detect => [$perl, "$repo/bin/overlay_command.pl", '-', '-', 'detect'],
                ls => ['bash', "$repo/envmaker.sh", 'ls'],
                del => ['bash', "$repo/envmaker.sh", '--yes', 'del'],
                'delete-preview' => ['bash', "$repo/envmaker.sh", '--yes', '--dry-run', 'del'],
                'exec-delete' => ['bash', "$repo/envmaker.sh", '--yes', 'execstow', 'delete'],
                stow => ['bash', "$repo/envmaker.sh", '--yes', 'execstow', 'stow'],
                restow => ['bash', "$repo/envmaker.sh", 'execstow', 'restow'],
                'apply-preview' => ['bash', "$repo/envmaker.sh", '--dry-run', 'execstow', 'restow'],
                migrate => ['bash', "$repo/envmaker.sh", '--yes', 'migrate', '--from', 'generic'],
                'migrate-preview' => ['bash', "$repo/envmaker.sh", '--dry-run', 'migrate', '--from', 'generic'],
                (map { ("recover-$_" => ['bash', "$repo/envmaker.sh", 'recover', $_]) } qw(inspect resume restore)),
                completion => [$perl, "$repo/tests/overlay_state_driver.pl", 'completion', '--source', 'personal', '--no-stow', 'printf'],
                'remove-keyword' => ['bash', "$repo/util/remove_function_keyword.sh", '--source', 'personal'],
                'convert-aliases' => ['bash', "$repo/util/convert_aliases_to_functions.sh", '--source', 'personal'],
                'legacy-del' => ['bash', "$repo/envmaker.sh", '--yes', 'del'],
                'legacy-delete' => ['bash', "$repo/envmaker.sh", '--yes', 'execstow', 'delete'],
                (map { ("$_-verify" => [$perl, "$repo/bin/mutation_guard.pl", 'verify', $_]) } qw(legacy legacy-preview writer writer-preview)));
            my ($ok, $output, $error) = driver($f, 'entry-probe', $inherit, @{$commands{$entry}});
            ok($ok, 'owned parent lock probe exits normally') or diag($error, $output);
            next unless $ok;
            my $probe = JSON::PP->new->utf8->decode($output);
            if ($inherit eq 'valid') {
                ok($probe->{ok}, "$entry accepts verified inherited descriptor") or diag($probe->{error}, $probe->{output});
            } else {
                ok(!$probe->{ok}, "$entry rejects $inherit descriptor");
                like($probe->{error}, $inherit eq 'missing' ? qr/lock is held|Missing inherited target lock/ : qr/Invalid inherited target lock descriptor/,
                    'negative control fails at shared lock validation');
            }
            ok(!$probe->{independent_shared} && $probe->{probe_error} =~ /lock is held/, "$entry never downgrades or releases parent EX");
            if ($inherit eq 'valid' && $entry eq 'migrate') {
                my $owner = Dotfiletracker::TargetGuard::read_json("$f->{home}/.dotfiletracker-owner.json");
                ok($owner->{protected} && $owner->{owner_state} eq $f->{state}, 'parent finish preserves nested migration ownership publication');
            }
        }
    }
};

case_test 'target lock contention, process identity and a removed-guard negative control' => sub {
    for my $enabled ($ENV{DFT_TEST_REVERSE} ? (1, 0) : (0, 1)) {
        my $f = fixture();
        pipe(my $ready_read, my $ready_write) or die $!;
        pipe(my $release_read, my $release_write) or die $!;
        my $pid = fork(); defined $pid or die $!;
        if (!$pid) {
            close $ready_read; close $release_write;
            local %ENV = %{$f->{env}};
            my $guard = $enabled ? Dotfiletracker::TargetGuard->new(mode => 'legacy') : undef;
            print {$ready_write} 'R'; close $ready_write;
            local $SIG{ALRM} = sub { POSIX::_exit(124) }; alarm 15;
            read($release_read, my $go, 1); close $release_read;
            $guard->finish if $guard;
            POSIX::_exit(0);
        }
        close $ready_write; close $release_read;
        local $SIG{ALRM} = sub { die "Lock fixture deadline exceeded\n" }; alarm 15;
        read($ready_read, my $ready, 1) == 1 or die 'Lock holder failed'; close $ready_read;
        $f->{env}{XDG_STATE_HOME} = "$f->{base}/different-state";
        my ($ok, undef, $err) = run($f, $perl, "$repo/bin/mutation_guard.pl", 'run', 'legacy', '--', 'true');
        if ($enabled) {
            ok(!$ok && $err =~ /lock is held/, 'different XDG state cannot bypass held target lock');
            is(Dotfiletracker::TargetGuard::read_json("$f->{home}/.dotfiletracker-owner.json")->{holder}{pid}, $pid, 'record identifies the live lock holder');
        } else { ok($ok, 'negative control: removing the guard allows the overlapping operation'); }
        print {$release_write} 'G'; close $release_write;
        waitpid($pid, 0); is($?, 0, 'owned lock-holder process released and reaped'); alarm 0;
    }
};

done_testing();
