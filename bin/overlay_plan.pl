#!/usr/bin/env perl
use strict;
use warnings;
use File::Basename ();
use lib File::Basename::dirname(__FILE__);
use Encode qw(decode FB_CROAK);
use JSON::PP;
use Dotfiletracker::StowRuntime qw(load_stow);
use Dotfiletracker::OverlayPlanner qw(build_plan read_registry);

sub usage { return "Usage: overlay_plan.pl STOW_EXEC VERSION plan|explain [TARGET]\nRead-only: frozen source/package registry on stdin; JSON on stdout.\n"; }
if (@ARGV == 1 && ($ARGV[0] eq '-h' || $ARGV[0] eq '--help')) { print usage(); exit 0; }
@ARGV >= 3 or die usage();
my ($executable, $version, $command, @args) = @ARGV;
($command eq 'plan' && !@args) || ($command eq 'explain' && @args == 1) or die usage();
my $target;
if ($command eq 'explain') {
    $target = decode('UTF-8', $args[0], FB_CROAK);
    $target ne '' && $target !~ m{\A/|(?:\A|/)\.{1,2}(?:/|\z)|//|/\z}
        or die "overlay: explain requires a normalized home-relative target\n";
}
my $runtime = load_stow($executable, $version);
my ($sources, $packages) = read_registry(\*STDIN);
my $plan = build_plan($sources, $packages, $runtime);
my $result = $plan;
if ($command eq 'explain') {
    my ($entry) = grep { $_->{target} eq $target } @{$plan->{targets}};
    $result = { target => $target, selected => $entry ? JSON::PP::true : JSON::PP::false,
                owner => $entry ? $entry->{owner} : undef,
                shadowed => $entry ? $entry->{shadowed} : [] };
}
print JSON::PP->new->canonical->utf8->encode($result), "\n";
