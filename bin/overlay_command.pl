#!/usr/bin/env perl
use strict;
use warnings;
use File::Basename qw(dirname);
use lib dirname(__FILE__);
use Dotfiletracker::OverlayPlanner;
use Dotfiletracker::OverlayState;
use Dotfiletracker::StowRuntime qw(load_stow);

sub application_enabled { return 1; }
my ($executable, $version, $action, $preview, $command, $from, @registry) = @ARGV;
if (!defined $action || $action eq '--help' || $action eq '-h') {
    print "Usage: overlay_command.pl STOW VERSION detect|ls|apply|delete|migrate PREVIEW COMMAND FROM [ID ROOT ...]\nInternal envmaker frontend; JSON stdout. PREVIEW=1 never writes persistent state.\n";
    exit(defined $action ? 0 : 1);
}
if ($action eq 'detect') {
    my $guard = Dotfiletracker::TargetGuard->for_entry(mode => 'inspect');
    my $receipt = Dotfiletracker::TargetGuard::read_json("$guard->{state}/applied.json");
    exit($guard->{record}{protected} || $guard->{record}{intent} || ($receipt && $receipt->{generation}) ? 0 : 1);
}
if ($action eq 'enabled') {
    application_enabled() or die "dotfiletracker: Stack mutation is disabled until overlay recovery and migration are implemented\n";
    exit 0;
}
$action =~ /^(?:ls|apply|delete|migrate)$/ && defined $preview && $preview =~ /^[01]$/ && @registry % 2 == 0
    or die "Invalid overlay command\n";
if ($action ne 'ls' && !application_enabled()) {
    die "dotfiletracker: Stack mutation is disabled until overlay recovery and migration are implemented\n";
}
my (@roots, @selectors);
while (@registry) {
    my ($id, $root) = splice @registry, 0, 2;
    push @roots, $root;
    push @selectors, '--source', "$id=$root";
}
my $runtime = $action eq 'ls' ? undef : load_stow($executable, $version);
my $state = Dotfiletracker::OverlayState->new(mode => $preview || $action eq 'ls' ? 'inspect' : 'stack',
    runtime => $runtime, source_roots => \@roots, verbose => $ENV{DFT_OVERLAY_VERBOSE} || $ENV{DFT_OVERLAY_DEBUG});
my $discover = sub {
    my @flags = $ENV{DFT_OVERLAY_DEBUG} ? ('--debug') : $ENV{DFT_OVERLAY_VERBOSE} ? ('--verbose') : ();
    my ($ok, $out, $err) = Dotfiletracker::OverlayPlanner::capture('bash', dirname(dirname(__FILE__)) . '/envmaker.sh', @flags, @selectors, 'plan');
    print STDERR $err if length $err;
    $ok or die "Overlay discovery failed\n";
    return Dotfiletracker::TargetGuard::json()->decode($out);
};
my $result = $action eq 'ls' ? $state->inspect_applied : $action eq 'delete'
    ? ($preview ? $state->preview_delete : $state->delete_applied)
    : $action eq 'migrate' ? $state->migrate($discover, $from, $preview)
    : $preview ? $state->preview($discover) : $state->apply($discover, $command);
print Dotfiletracker::TargetGuard::json()->encode($result), "\n";
