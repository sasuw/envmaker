#!/usr/bin/env perl
use strict;
use warnings;
use File::Basename ();
use POSIX ();
use lib File::Basename::dirname(__FILE__);
use Dotfiletracker::TargetGuard;
use Dotfiletracker::OverlayState;

if (@ARGV == 1 && $ARGV[0] =~ /^--?h(?:elp)?$/) {
    print "Usage: mutation_guard.pl verify|run legacy|legacy-preview [-- COMMAND ...]\n       mutation_guard.pl external -- COMMAND ...\nShared target lock and stack-ownership guard. legacy-preview never creates a lock.\n";
    exit 0;
}
my ($action, $mode, @command) = @ARGV;
if (defined $action && $action eq 'external') {
    defined $mode && $mode eq '--' && @command or die "Missing external command\n";
    Dotfiletracker::TargetGuard->exec_external(@command);
}
defined $mode && $mode =~ /^(?:legacy|writer)(?:-preview)?$/ && defined $action && $action =~ /^(?:verify|run)$/
    or die "Invalid mutation guard invocation\n";
$action ne 'verify' || defined $ENV{DFT_GUARD_FD} or die "Missing inherited target lock\n";
my $state;
my $guard;
if ($mode =~ /^writer/) {
    my (@roots, @paths, $write_root);
    while (@command && $command[0] =~ /^--(?:source-root|write-target|write-root)$/) {
        my $option = shift @command;
        @command or die "Missing writer source root\n";
        if ($option eq '--write-root') { $write_root = shift @command; }
        else { push @{$option eq '--source-root' ? \@roots : \@paths}, shift @command; }
    }
    $state = Dotfiletracker::OverlayState->new(mode => $mode eq 'writer-preview' ? 'inspect' : 'stack', source_roots => \@roots);
    $guard = $state->writer_guard($mode eq 'writer-preview', \@paths, $write_root);
} else {
    $guard = Dotfiletracker::TargetGuard->for_entry(mode => $mode);
}
exit 0 if $action eq 'verify';
shift @command if @command && $command[0] eq '--';
@command or die "Missing guarded command\n";
my $pid = fork();
defined $pid or die "Cannot fork guarded command: $!\n";
if (!$pid) {
    $ENV{DFT_GUARD_FD} = $guard->inherited_fd if $guard->{fh};
    delete $ENV{DFT_GUARD_FD} unless $guard->{fh};
    exec { $command[0] } @command;
    warn "Cannot execute guarded command: $!\n";
    POSIX::_exit(127);
}
waitpid($pid, 0);
my $status = $?;
$guard->finish unless $mode =~ /-preview$/;
exit($status == -1 ? 127 : ($status & 127) ? 128 + ($status & 127) : $status >> 8);
