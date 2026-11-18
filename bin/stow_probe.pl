#!/usr/bin/env perl
use strict;
use warnings;
use File::Basename ();
use lib File::Basename::dirname(__FILE__);
use JSON::PP;
use Dotfiletracker::StowRuntime qw(load_stow);

if (@ARGV == 1 && ($ARGV[0] eq '--help' || $ARGV[0] eq '-h')) {
    print "Usage: stow_probe.pl STOW_EXEC EXPECTED_VERSION\nRead-only probe; use bin/stow_bridge.sh to select Stow's interpreter.\n";
    exit 0;
}
@ARGV == 2 or die "Usage: stow_probe.pl STOW_EXEC EXPECTED_VERSION\n";
print JSON::PP->new->canonical->encode(load_stow(@ARGV)), "\n";
