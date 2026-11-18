#!/usr/bin/env perl
use strict;
use warnings;
use File::Basename ();
use lib File::Basename::dirname(__FILE__);
use Dotfiletracker::OverlayState;
use Dotfiletracker::StowRuntime qw(load_stow);
my ($exe, $version, @arguments) = @ARGV;
@ARGV = @arguments;
if (@ARGV == 1 && $ARGV[0] =~ /^--?h(?:elp)?$/) {
    print "Usage: envmaker.sh recover inspect|resume|restore\nUses HOME and XDG_STATE_HOME only; no source discovery. inspect is read-only.\n";
    exit 0;
}
@ARGV == 1 && $ARGV[0] =~ /^(?:inspect|resume|restore)$/ or die "Usage: envmaker.sh recover inspect|resume|restore\n";
my $action = $ARGV[0];
if ($action ne 'inspect') {
    # Re-exec through the same configured interpreter used by apply/transition.
    # The helper is loaded from a fixed repository path, never from state JSON.
    my $runtime = load_stow($exe, $version);
    my $state = Dotfiletracker::OverlayState->new(mode => 'recovery', runtime => $runtime);
    print Dotfiletracker::TargetGuard::json()->encode($state->recover($action)), "\n";
} else {
    my $state = Dotfiletracker::OverlayState->new(mode => 'inspect');
    print Dotfiletracker::TargetGuard::json()->encode($state->recover($action)), "\n";
}
