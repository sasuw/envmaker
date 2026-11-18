#!/usr/bin/env perl
use strict;
use warnings;
use File::Basename ();
use lib File::Basename::dirname(__FILE__);
use Dotfiletracker::StowRuntime qw(load_stow);
@ARGV == 7 or die "Usage: stow_transition.pl STOW_EXEC VERSION STOW_DIR TARGET SIMULATE OLD NEW\nInternal controlled transition; no CLI resource-file parsing.\n";
my ($exe, $version, $directory, $target, $simulate, $old, $new) = @ARGV;
load_stow($exe, $version);
my @old = $old eq '-' ? () : split /,/, $old;
for my $id (@old, $new) { $id eq '-' || $id =~ /^generation_[a-f0-9]{32}$/ or die "Invalid generation\n"; }
my $stow = Stow->new(dir => $directory, target => $target, 'no-folding' => 1);
my %seen;
$stow->plan_unstow(grep { !$seen{$_}++ } @old) if @old;
$stow->plan_stow($new) if $new ne '-';
my %conflicts = $stow->get_conflicts;
keys %conflicts and die "Stow reported transition conflicts: " .
    join('; ', map { my $action = $_; map { @{$conflicts{$action}{$_}} } keys %{$conflicts{$action}} } keys %conflicts) . "\n";
$stow->process_tasks unless $simulate;
