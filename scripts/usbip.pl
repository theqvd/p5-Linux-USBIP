#!/usr/bin/env perl

use v5.10;
use warnings;
use strict;

use Switch;
use Linux::USBIP;

my $usbip = Linux::USBIP->new();

switch ( $ARGV[0] ){

  case 'bind' {
    say "Binding $ARGV[1]:";
    unless ($usbip->bind_dev($ARGV[1])) { say $usbip->{last_error} };
  }
    
  case 'unbind' {
    say "Unbinding $ARGV[1]:";
    unless ($usbip->unbind_dev($ARGV[1])) { say $usbip->{last_error} };
  }
  case 'release' {
    say "Releasing port $ARGV[1]:";
    unless ($usbip->release_dev($ARGV[1])) { say $usbip->{last_error} };
  }
  else { print "Usage: usbip.pl [COMMAND] [PARAMETER]\n\n\t* bind <device-id>\n\t* unbind <device-id>\n\t* release <port>\n\n"; }
}
