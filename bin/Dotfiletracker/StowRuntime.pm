package Dotfiletracker::StowRuntime;
use strict;
use warnings;
use Cwd qw(abs_path);
use Exporter 'import';
our @EXPORT_OK = qw(load_stow);

sub load_stow {
    my ($executable, $expected_version) = @_;
    $executable = abs_path($executable) or die "Cannot resolve Stow executable\n";
    {
        package Dotfiletracker::InstalledStow;
        # Installed Stow guards main() with caller(). Loading its CLI imports
        # precisely its own module setup, including relocatable installations.
        local $0 = $executable;
        my $loaded = do $executable;
        die "Cannot load $executable: " . ($@ || $! || 'unknown error') . "\n"
            unless defined $loaded;
    }
    my $module = abs_path($INC{'Stow.pm'} || '')
        or die "Stow did not load a discoverable Stow.pm: $executable\n";
    my $version = $Stow::VERSION;
    defined $version && $version eq $expected_version
        or die "Stow module version mismatch at $module (expected $expected_version)\n";
    open my $cli, '-|', $^X, $executable, '--version'
        or die "Cannot execute $executable: $!\n";
    my $output = do { local $/; <$cli> };
    close $cli or die "Stow --version failed: $executable\n";
    $output =~ /\(GNU Stow\) version \Q$version\E(?:\s|$)/
        or die "Stow CLI/module version mismatch: $executable and $module\n";
    return { executable => $executable, interpreter => $^X,
             module => $module, version => $version };
}

1;
