#!/usr/bin/env perl

use warnings;
use strict;

use IO::Socket::INET;
use Socket qw/IPPROTO_TCP TCP_NODELAY SOL_SOCKET SO_REUSEADDR SO_KEEPALIVE/;
use Linux::USBIP;

@ARGV == 2 or die "Usage: connect.pl <ip> <device>\n\n";

my ($target, $busid) = @ARGV;
my ($host, $port) = $target =~ /^(.*?)(?::(\d+))?$/ or die "Bar target $target\n";

my $sock = IO::Socket::INET->new(PeerAddr => $host,
                                 PeerPort => ($port || 3240),
                                 Proto    => 'tcp');

die "cannot connect to the server $!\n" unless $sock;

$sock->setsockopt(SOL_SOCKET,SO_REUSEADDR,1);
$sock->setsockopt(SOL_SOCKET,SO_KEEPALIVE,1);

my $usbip = Linux::USBIP->new();
$usbip->bind($busid) // warn "Bind failed: $!\n";
if (my ($devid, $speed) = $usbip->export($busid, $sock)) {
    $sock->send("$devid $speed\n");
}
else {
    die $!;
}

