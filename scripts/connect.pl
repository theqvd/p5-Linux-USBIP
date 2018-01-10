#!/usr/bin/env perl

use warnings;
use strict;

use IO::Socket::INET;
use Socket qw/IPPROTO_TCP TCP_NODELAY SOL_SOCKET SO_REUSEADDR SO_KEEPALIVE/;
use Linux::USBIP;

@ARGV == 2 or die "Usage: connect.pl <ip> <device>\n\n";

my $sock = IO::Socket::INET->new(PeerAddr => $ARGV[0],
                                 PeerPort => '3240',
                                 Proto    => 'tcp');

die "cannot connect to the server $!\n" unless $sock;

$sock->setsockopt(SOL_SOCKET,SO_REUSEADDR,1);
$sock->setsockopt(SOL_SOCKET,SO_KEEPALIVE,1);

my $usbip = Linux::USBIP->new();
my $export_info = $usbip->export_dev($ARGV[1],fileno $sock);

$export_info or die "Couldn't export device: ".$usbip->{error_msg};

$sock->send($export_info);

