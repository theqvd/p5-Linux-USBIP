#!/usr/bin/env perl

use warnings;
use strict;

use IO::Socket::INET;
use Socket qw/IPPROTO_TCP TCP_NODELAY SOL_SOCKET SO_REUSEADDR SO_KEEPALIVE/;
use Linux::USBIP;

my $received;
my $len=1024;

my $usbip = Linux::USBIP->new();

my $sock = IO::Socket::INET->new(Listen    => 5,
                                 LocalPort => '3240',
                                 Proto     => 'tcp',
                                 Reuse     => 1 )
  or die "Can't open socket";

$sock->setsockopt(SOL_SOCKET,SO_REUSEADDR,1);
$sock->setsockopt(SOL_SOCKET,SO_KEEPALIVE,1);

while(1){
  if (my $newcon = $sock->accept()){
    $newcon->recv($received,$len);
    $received or next;
    print "host: ".$newcon->peerhost()."\n";
    print "port: ".$newcon->peerport()."\n";
    print "recv: ".$received."\n";

    $newcon->setsockopt(IPPROTO_TCP,TCP_NODELAY,1);
    my $result = $usbip->import_dev($received,fileno $newcon,$newcon->peerhost(),$newcon->peerport());
  }
}

