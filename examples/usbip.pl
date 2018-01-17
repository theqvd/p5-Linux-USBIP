#!/usr/bin/env perl

use v5.10;
use warnings;
use strict;

use Linux::USBIP;

my $usbip = Linux::USBIP->new();

my $cmd = shift // die "Subcommand missing\n";
my $busid = shift // die "BusId argument missing\n";

if ($cmd eq 'bind') {
    say "Binding $busid";
    $usbip->bind($busid) // die $!;
}
elsif ($cmd eq 'unbind') {
    say "Unbinding $busid";
    $usbip->unbind($busid) // die $!;
}
elsif ($cmd eq 'release') {
    say "Releasing port $busid";
    $usbip->release($busid) // die $!;
}
else {
    die <<EOU;
Usage:

  $0 [COMMAND] [PARAMETER]
     bind <device-id>
     unbind <device-id>
     release <port>

EOU
}
