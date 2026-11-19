#!/usr/bin/env perl
use strict;
use warnings;
use Cwd qw(abs_path getcwd);
use Encode qw(decode FB_CROAK);
use File::Basename qw(dirname);
use File::Find;
use File::Path qw(make_path);
use IO::Select;
use IPC::Open3;
use JSON::PP;
use POSIX ();
use Symbol qw(gensym);
use Test::More;
use lib dirname(dirname(abs_path(__FILE__))) . '/bin';
use Dotfiletracker::OverlayPlanner qw(build_plan);

use lib dirname(abs_path(__FILE__));
use FixtureLifecycle;

my $repo = dirname(dirname(abs_path(__FILE__)));
my $suite = FixtureLifecycle::suite_root('envmaker-planner.', $^X, abs_path(__FILE__), @ARGV);
my $serial = 0;

sub text { my $bytes = $_[0]; return decode('UTF-8', $bytes, FB_CROAK); }
sub write_file {
    my ($file, $bytes) = @_;
    make_path(dirname($file));
    open my $fh, '>', $file or die "$file: $!";
    binmode $fh;
    print {$fh} $bytes;
    close $fh or die "$file: $!";
}
sub read_file {
    open my $fh, '<', $_[0] or die "$_[0]: $!";
    return do { local $/; <$fh> };
}
sub fixture {
    my $root = "$suite/" . ++$serial;
    my $home = "$root/home";
    make_path("$home/.config/dotfiletracker", "$root/caller");
    my %env = (%ENV, HOME => $home, XDG_CONFIG_HOME => "$home/.config",
        XDG_STATE_HOME => "$home/.local/state", XDG_DATA_HOME => "$home/.local/share",
        XDG_CACHE_HOME => "$home/.cache", TERM => 'dumb', GIT_CONFIG_NOSYSTEM => 1,
        GIT_CONFIG_GLOBAL => '/dev/null');
    delete @env{qw(BASH_ENV ENV)};
    my $fixture = { root => $root, env => \%env, cwd => "$root/caller",
                    generic => "$root/generic", personal => "$root/personal space ü:=x" };
    for my $id (qw(generic personal)) { make_path("$fixture->{$id}/parts", "$fixture->{$id}/common"); }
    write_file("$home/.config/dotfiletracker/config",
        "source.generic=$fixture->{generic}\nsource.personal=\"$fixture->{personal}\"\n");
    return $fixture;
}
sub run_command {
    my ($fixture, @args) = @_;
    local %ENV = %{$fixture->{env}};
    my $old_cwd = getcwd();
    chdir $fixture->{cwd} or die $!;
    my ($in, $out, $err) = (undef, undef, gensym());
    my $pid = open3($in, $out, $err, @args);
    chdir $old_cwd or die $!;
    close $in;
    my $select = IO::Select->new($out, $err);
    my ($stdout, $stderr) = ('', '');
    my $out_fd = fileno $out;
    while (my @ready = $select->can_read) {
        for my $fh (@ready) {
            my $count = sysread($fh, my $buffer, 65536);
            defined $count or die $!;
            if (!$count) { $select->remove($fh); close $fh; next; }
            if (fileno($fh) == $out_fd) { $stdout .= $buffer; } else { $stderr .= $buffer; }
        }
    }
    waitpid($pid, 0);
    return ($?, $stdout, $stderr);
}
sub command_ok {
    my ($fixture, @command) = @_;
    my ($rc, $out, $err) = run_command($fixture, @command);
    is($rc, 0, "command succeeds: $command[0] $command[1]") or diag($err, $out);
    return $out;
}
sub get_plan {
    my ($fixture) = @_;
    my $bytes = command_ok($fixture, 'bash', "$repo/envmaker.sh", 'plan');
    return JSON::PP->new->utf8->decode($bytes);
}
sub rejected {
    my ($fixture, $diagnostic, @arguments) = @_;
    @arguments = ('plan') unless @arguments;
    my ($rc, $out, $err) = run_command($fixture, 'bash', "$repo/envmaker.sh", @arguments);
    isnt($rc, 0, 'planning rejects invalid input');
    is($out, '', 'no partial JSON plan is published');
    like($err, $diagnostic, 'failure explains the rejected input');
    ok(!-e "$fixture->{env}{XDG_STATE_HOME}/dotfiletracker", 'no persistent stack state created');
}

subtest 'source IDs use the exact ASCII alphabet independently of locale' => sub {
    my $f = fixture();
    local %ENV = %{$f->{env}};
    my $cwd = getcwd(); chdir $f->{cwd} or die $!;
    for my $id ('a', 'Z', '0', 'valid_A-9') {
        my $plan = eval { build_plan([{id => $id, root => $f->{generic}}], [], {}); };
        ok($plan && $plan->{sources}[0]{id} eq $id, 'valid ASCII ID accepted') or diag($@);
    }
    for my $id ('', 'ü', 'aü', '١', '_start', '-start', "valid\n") {
        eval { build_plan([{id => $id, root => $f->{generic}}], [], {}); };
        like($@, qr/Invalid source ID/, 'invalid or trailing-newline ID rejected');
    }
    chdir $cwd or die $!;
};

subtest 'whole-file precedence for crossed presence/content and empty sets' => sub {
    for my $lower ('', 'same', 'lower') {
        for my $upper ('', 'same', 'upper') {
            my $f = fixture();
            write_file("$f->{generic}/common/lower-name/.setting", $lower) if length $lower;
            write_file("$f->{personal}/common/upper-name/.setting", $upper) if length $upper;
            my $plan = get_plan($f);
            my $present = length($lower) || length($upper);
            is(scalar @{$plan->{targets}}, $present ? 1 : 0, 'selected set matches presence');
            next unless $present;
            my $entry = $plan->{targets}[0];
            is($entry->{owner}{source_id}, length($upper) ? 'personal' : 'generic', 'later source wins, independent of package name/content');
            is(scalar @{$entry->{shadowed}}, length($upper) && length($lower) ? 1 : 0, 'shadow inventory retained');
            is($entry->{target}, '.setting', 'target is home-relative');
        }
    }
};

subtest 'fork provenance, unchanged upper copies and lower inheritance' => sub {
    my $f = fixture();
    write_file("$f->{generic}/common/lower/.setting", "generic\n");
    write_file("$f->{generic}/parts/.gitkeep", '');
    for my $cmd (['init', '--quiet'], ['add', '.'],
            ['-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid',
             '-c', 'core.hooksPath=/dev/null', 'commit', '--quiet', '-m', 'fixture']) {
        command_ok($f, 'git', '-C', $f->{generic}, @$cmd);
    }
    rename $f->{personal}, "$f->{personal}-unused" or die $!;
    command_ok($f, 'git', 'clone', '--quiet', '--no-hardlinks', $f->{generic}, $f->{personal});
    rename "$f->{personal}/common/lower", "$f->{personal}/common/upper" or die $!;
    write_file("$f->{personal}/common/upper/.setting", "personal secret contents\n");
    my $original = read_file("$f->{generic}/common/lower/.setting");
    my $p = get_plan($f);
    is($p->{targets}[0]{owner}{source_id}, 'personal', 'edited fork wins');
    is($p->{sources}[0]{git}{dirty}, JSON::PP::false, 'generic remains clean');
    is($p->{sources}[1]{git}{dirty}, JSON::PP::true, 'dirty fork is accepted');
    like($p->{sources}[0]{git}{commit}, qr/^[a-f0-9]{40}$/, 'source commit recorded');
    is(read_file("$f->{generic}/common/lower/.setting"), $original, 'generic bytes unchanged');
    write_file("$f->{generic}/common/lower/.setting", "upstream changed\n");
    is(get_plan($f)->{targets}[0]{owner}{source_id}, 'personal', 'unchanged fork copy still wins over upstream edit');
    unlink "$f->{personal}/common/upper/.setting" or die $!;
    is(get_plan($f)->{targets}[0]{owner}{source_id}, 'generic', 'upper deletion restores lower candidate');
    unlink "$f->{generic}/common/lower/.setting" or die $!;
    is_deeply(get_plan($f)->{targets}, [], 'removing both empties the planned target set');
};

subtest 'ignore precedence matches real Stow for crossed local/global policies' => sub {
    my $version = $ENV{STOW_VERSION} || '2.4.1';
    for my $global ('absent', 'comment', 'filter') {
        for my $local ('absent', 'comment', 'filter') {
            my $f = fixture();
            my $package = "$f->{generic}/common/pkg";
            for my $name ('.gitignore', 'README.md', 'keep', 'drop', '.config/dropped/value', '.config/keep', 'temp~') {
                write_file("$package/$name", "value\n");
            }
            write_file("$f->{env}{HOME}/.stow-global-ignore", $global eq 'filter' ? "drop\n" : "# disable defaults\n") unless $global eq 'absent';
            write_file("$package/.stow-local-ignore", $local eq 'filter' ? "drop\n^/\\.config/dropped\n" : "# disable defaults\n") unless $local eq 'absent';
            my $p = get_plan($f);
            my $target = "$f->{root}/real-stow-target";
            make_path($target);
            command_ok($f, "/opt/stow-$version/bin/stow", "--dir=$f->{generic}/common",
                "--target=$target", '--no-folding', '--stow', 'pkg');
            my @linked;
            find({ no_chdir => 1, wanted => sub {
                push @linked, text(substr($File::Find::name, length($target) + 1)) if -l $File::Find::name;
            } }, $target);
            is_deeply([sort map { $_->{target} } @{$p->{targets}}], [sort @linked], "planner matches real Stow: global=$global local=$local");
        }
    }
    my $f = fixture();
    write_file("$f->{generic}/common/lower/.setting", 'generic');
    write_file("$f->{personal}/common/upper/.setting", 'personal');
    write_file("$f->{personal}/common/upper/.stow-local-ignore", "^/\\.setting\$\n");
    is(get_plan($f)->{targets}[0]{owner}{source_id}, 'generic', 'ignored upper entry does not hide lower');
    write_file("$f->{personal}/common/upper/.stow-local-ignore", "[invalid\n");
    rejected($f, qr/Invalid ignore policy.*upper/s);
};

subtest 'same-source and structural collisions include both owners' => sub {
    my $f = fixture();
    write_file("$f->{generic}/common/a/.setting", 'a');
    write_file("$f->{generic}/common/b/.setting", 'b');
    rejected($f, qr/Same-source.*generic:common\/a.*generic:common\/b/s);
    for my $lower ('file', 'directory') {
        for my $upper ('file', 'directory') {
            for my $same_source (0, 1) {
                my $f = fixture();
                my $upper_root = $same_source ? $f->{generic} : $f->{personal};
                write_file("$f->{generic}/common/a/.node" . ($lower eq 'directory' ? '/lower' : ''), 'a');
                write_file("$upper_root/common/b/.node" . ($upper eq 'directory' ? '/upper' : ''), 'b');
                if ($lower ne $upper) { rejected($f, qr/File\/directory collision.*common\/a.*common\/b/s); }
                elsif ($lower eq 'file' && $same_source) { rejected($f, qr/Same-source target ambiguity/); }
                else { ok(@{get_plan($f)->{targets}} > 0, 'compatible exact overlay or shared directory accepted'); }
            }
        }
    }
};

subtest 'portable case and Unicode spelling aliases rejected' => sub {
    for my $pair (['.Case', '.case'], ["\xc3\xa9", "e\xcc\x81"], ['.config/Tool/a', '.config/tool/b']) {
        my $f = fixture();
        write_file("$f->{generic}/common/a/$pair->[0]", 'a');
        write_file("$f->{personal}/common/b/$pair->[1]", 'b');
        rejected($f, qr/Target spelling alias.*generic:.*personal:/s);
    }
};

subtest 'source priority order, explicit removal and rule execution once' => sub {
    my $f = fixture();
    write_file("$f->{generic}/common/z/.setting", 'lower');
    write_file("$f->{personal}/common/a/.setting", 'upper');
    my $reversed = JSON::PP->new->utf8->decode(command_ok($f, 'bash', "$repo/envmaker.sh",
        '--source', "personal=$f->{personal}", '--source', "generic=$f->{generic}", 'plan'));
    is($reversed->{targets}[0]{owner}{source_id}, 'generic', 'CLI order controls priority');
    my $removed = JSON::PP->new->utf8->decode(command_ok($f, 'bash', "$repo/envmaker.sh",
        '--source', "generic=$f->{generic}", 'plan'));
    is($removed->{targets}[0]{owner}{source_id}, 'generic', 'explicit source removal changes candidate membership');
    is_deeply($removed->{targets}[0]{shadowed}, [], 'removed source is absent from shadow inventory');
    my $third = "$f->{root}/third";
    make_path("$third/parts");
    write_file("$third/common/another/.setting", 'last');
    my $three = JSON::PP->new->utf8->decode(command_ok($f, 'bash', "$repo/envmaker.sh",
        '--source', "generic=$f->{generic}", '--source', "personal=$f->{personal}",
        '--source', "third=$third", 'plan'));
    is($three->{targets}[0]{owner}{source_id}, 'third', 'third source wins');
    is_deeply([map { $_->{source_id} } @{$three->{targets}[0]{shadowed}}],
        ['generic', 'personal'], 'shadowed owners retain low-to-high order');
    for my $id (qw(generic personal)) {
        write_file("$f->{$id}/parts/feature/pkg/.rule-setting", $id);
        write_file("$f->{$id}/rules/feature", '#!/bin/sh' . "\n" .
            'printf "%s|%s|%s\n" "$DOTFILES_DIR" "$DOTFILETRACKER_SOURCE_ID" "$PWD" >> "$HOME/rule-marker"' . "\n" .
            'test "$DOTFILETRACKER_SOURCE_ID" = generic' . "\n");
        chmod 0755, "$f->{$id}/rules/feature";
    }
    my $p = get_plan($f);
    my ($rule_entry) = grep { $_->{target} eq '.rule-setting' } @{$p->{targets}};
    is($rule_entry->{owner}{source_id}, 'generic', 'inactive upper rule does not suppress lower');
    my @lines = split /\n/, read_file("$f->{env}{HOME}/rule-marker");
    is_deeply(\@lines, ["$f->{generic}|generic|$f->{cwd}", "$f->{personal}|personal|$f->{cwd}"],
        'rules execute exactly once with source-local context and caller cwd');
    ok(!-e "$f->{env}{XDG_STATE_HOME}", 'trusted rule effects do not create wrapper applied state');
};

subtest 'source entry types, filenames and executable mode' => sub {
    my $f = fixture();
    my $package = "$f->{generic}/common/a";
    my $name = "file ü:=x\nnext";
    write_file("$package/$name", 'source secret content');
    chmod 0755, "$package/$name";
    symlink $name, "$package/link" or die $!;
    my $p = get_plan($f);
    my ($file) = grep { $_->{target} eq text($name) } @{$p->{targets}};
    is($file->{owner}{mode}, 0755, 'executable mode recorded');
    my ($link) = grep { $_->{target} eq 'link' } @{$p->{targets}};
    is($link->{owner}{entry_type}, 'symlink', 'original link entry preserved');
    is($link->{owner}{link_text}, text($name), 'original link text recorded');
    write_file("$f->{root}/external-file", 'external regular target');
    symlink "$f->{root}/external-file", "$package/external-regular" or die $!;
    ok(grep($_->{target} eq 'external-regular', @{get_plan($f)->{targets}}), 'regular source symlink may resolve outside checkout without traversal');
    for my $type (qw(broken cycle directory fifo)) {
        my $f = fixture();
        my $entry = "$f->{generic}/common/a/bad";
        make_path(dirname($entry));
        if ($type eq 'broken') { symlink 'missing', $entry or die $!; }
        elsif ($type eq 'cycle') { symlink 'bad', $entry or die $!; }
        elsif ($type eq 'directory') { make_path("$f->{root}/external"); symlink "$f->{root}/external", $entry or die $!; }
        else { POSIX::mkfifo($entry, 0600) == 0 or die $!; }
        rejected($f, $type eq 'fifo' ? qr/Unsupported special source entry/ : $type eq 'directory' ? qr/does not resolve to a regular file/ : qr/Broken or cyclic source link/);
    }
    my $f2 = fixture();
    make_path("$f2->{root}/outside");
    symlink "$f2->{root}/outside", "$f2->{generic}/common/link-package" or die $!;
    rejected($f2, qr/Package directory.*symlink/);
};

subtest 'Stow resource options fail with exact file location' => sub {
    for my $location ('home', 'caller') {
        for my $option ('--adopt', '--target=/elsewhere', '--ignore=keep', '--dotfiles', '--override=.*', '--defer=.*') {
            my $f = fixture();
            my $directory = $location eq 'home' ? $f->{env}{HOME} : $f->{cwd};
            write_file("$directory/.stowrc", "$option\n");
            rejected($f, qr/Unsupported Stow resource option in .*\.stowrc.*:1/s);
        }
    }
    my $f = fixture();
    write_file("$f->{env}{HOME}/.stowrc", "# supported comment\n\n");
    is(scalar @{get_plan($f)->{resource_files}}, 1, 'comment-only rc fingerprint recorded');
};

subtest 'explain, determinism and no persistent planning state' => sub {
    my $f = fixture();
    write_file("$f->{generic}/common/a/.setting", 'not in explanation');
    write_file("$f->{personal}/common/b/.setting", 'secret not in explanation');
    my $first = command_ok($f, 'bash', "$repo/envmaker.sh", 'plan');
    is(command_ok($f, 'bash', "$repo/envmaker.sh", 'plan'), $first, 'same inputs produce byte-identical JSON');
    unlike($first, qr/secret not in explanation|not in explanation/, 'plan does not report file contents');
    my $verbose = command_ok($f, 'bash', "$repo/envmaker.sh", '--debug', '--dry-run', 'plan');
    is($verbose, $first, 'debug/dry-run diagnostics do not contaminate JSON output');
    my $explanation = JSON::PP->new->utf8->decode(command_ok($f, 'bash', "$repo/envmaker.sh", 'explain', '.setting'));
    is($explanation->{owner}{source_id}, 'personal', 'explain gives winner');
    is($explanation->{shadowed}[0]{source_id}, 'generic', 'explain gives shadowed lower');
    my $absent = JSON::PP->new->utf8->decode(command_ok($f, 'bash', "$repo/envmaker.sh", 'explain', '.absent'));
    ok(!$absent->{selected} && !defined $absent->{owner}, 'unselected target reported explicitly');
    for my $target ('', '../escape', '/absolute', 'a//b', './a', 'a/') {
        rejected($f, qr/normalized home-relative target/, 'explain', $target);
    }
    ok(!-e $f->{env}{XDG_STATE_HOME} && !-e "$f->{env}{HOME}/.setting", 'plan creates no generation, state or home target');
};

done_testing();
