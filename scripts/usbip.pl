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
    if ($usbip->bind($ARGV[1])) { 
      say "Ok!";
    }else{ 
      say "Error code: ".$usbip->{error};
      say $usbip->{error_msg}
    };
  }
    
  case 'unbind' {
    say "Unbinding $ARGV[1]:";
    if ($usbip->unbind($ARGV[1])) {
      say "Ok!";
    }else{  
      say "Error code: ".$usbip->{error};
      say $usbip->{error_msg}
    };
  }
  case 'release' {
    say "Releasing port $ARGV[1]:";
    if ($usbip->release($ARGV[1])) {
      say "Ok!";
    }else{  
      say "Error code: ".$usbip->{error};
      say $usbip->{error_msg}
    };
  }
  else { print "Usage: usbip.pl [COMMAND] [PARAMETER]\n\n\t* bind <device-id>\n\t* unbind <device-id>\n\t* release <port>\n\n"; }
}
