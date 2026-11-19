package FixtureLifecycle;
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);

sub suite_root {
    my ($prefix, @command) = @_;
    if (($ENV{DFT_FIXTURE_OWNER} // '') eq getppid()) {
        return $ENV{DFT_FIXTURE_ROOT};
    }
    exec 'python3', '-B', dirname(abs_path(__FILE__)) . '/fixture_lifecycle.py',
        '--prefix', $prefix, '--', @command;
    die "Cannot start fixture owner: $!\n";
}
1;
