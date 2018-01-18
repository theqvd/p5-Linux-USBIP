#!/usr/bin/env perl

use warnings;
use strict;

use IO::Socket::INET;
use Socket qw/IPPROTO_TCP TCP_NODELAY SOL_SOCKET SO_REUSEADDR SO_KEEPALIVE/;
use Linux::USBIP;


my $listener = IO::Socket::INET->new(Listen    => 5,
                                     LocalPort => '3240',
                                     Proto     => 'tcp',
                                     Reuse     => 1 )
  or die "Can't open socket";

$listener->setsockopt(SOL_SOCKET,SO_REUSEADDR,1);
$listener->setsockopt(SOL_SOCKET,SO_KEEPALIVE,1);

while(1) {
    my $buffer;
    if (my $sock = $listener->accept()){
        if (defined (my $line = <$sock>)) {
            if (my ($peerdevid, $speed) = $line =~ /^(\d+)\s+(\d+)$/) {
                $sock->setsockopt(IPPROTO_TCP,TCP_NODELAY,1);
                my $usbip = Linux::USBIP->new();
                $usbip->attach($sock, $peerdevid, $speed)
                    or warn "Unable to attach remote USB/IP device $peerdevid\n";
            }
        }
    }
}

