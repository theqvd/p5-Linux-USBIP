package Linux::USBIP;

use 5.006;
use strict;
use warnings;

use Cwd qw/abs_path/;
use Data::Dumper;

our $vhci_driver = "/sys/devices/platform/vhci_hcd.0/";
our $vhci_varrun = "/var/run/vhci_hcd/";
our $vhci_attach = "attach";
our $vhci_detach = "detach";
our $host_driver = "/sys/bus/usb/drivers/usbip-host/";
our $host_bind = $host_driver."bind";
our $host_unbind = $host_driver."unbind";
our $host_rebind = $host_driver."rebind";
our $host_match_busid = $host_driver."match_busid";
our $attr_sockfd = "/usbip_sockfd";
our $attr_status = "/usbip_status";
our %speed_map = (
                  '1.5'     => '1',
                  '12'      => '2',
                  '480'     => '3',
                  '5000'    => '5',
                  '10000'   => '6',
                  'unknown' => '0'
);
our %speed_to_string = (
                  '1' => 'hs',
                  '2' => 'hs',
                  '3' => 'hs',
                  '5' => 'ss',
                  '6' => 'ss',
                  '0' => 'hs'
);

=head1 NAME

Linux::USBIP - Library for using Linux's kernel usbip functions. 

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';


=head1 SYNOPSIS

Provide access to Linux kernel's usbip functions.
Different from usbip tool included with kernel sources. It doesn't have
a server function. This tool dependes on you creating a tcp socket on
both sides, so you choose which side is server and client.

Simple utility:

  use v5.10;
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

Simple Server:

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


Simple Client:

  use IO::Socket::INET;
  use Socket qw/IPPROTO_TCP TCP_NODELAY SOL_SOCKET SO_REUSEADDR SO_KEEPALIVE/;
  use Linux::USBIP;
  
  @ARGV == 2 or die "Usage: connect.pl <ip> <device>\n\n";
  
  my $sock = IO::Socket::INET->new(PeerAddr => $ARGV[0],
                                   PeerPort => '3240',
                                   Proto    => 'tcp');
  
  die "cannot connect to the server $!\n" unless $sock;
  
  my $usbip = Linux::USBIP->new();
  my $export_info = $usbip->export_dev($ARGV[1],fileno $sock);
  
  $export_info or die "Couldn't export device: ".$usbip->{last_error};
  
  $sock->send($export_info);


=head1 SUBROUTINES/METHODS

=head2 new

Module constructor

=cut

sub new {
  my $self = {
               last_error => ''
             };
  return bless $self;
}

=head2 bind_dev

Bind a device to usbip_host driver. (usbip_host side)
Expects busid.

=cut

sub bind_dev {
  my ($self,$busid) = @_;

  # Don't bind hubs
  open my $bDevClass , '<' , "/sys/bus/usb/devices/".$busid."/bDeviceClass" or
    ($self->{last_error} = "Can't find busid: ".$busid and return);
  if ( <$bDevClass> =~ /09/ ){
    $self->{last_error} = "busid: $busid is a hub. Won't do";
    return;
  }
  close $bDevClass;

  # Disconnect from driver
  my $driver = abs_path("/sys/bus/usb/devices/".$busid."/driver") or
    ($self->{last_error} = "Can't find busid: ".$busid and return);
  if ( $driver =~ /usbip-host/ ){
    $self->{last_error} = "busid: $busid is already binded";
    return;
  }
  $self->_write_sysfs($driver."/unbind",$busid) or return;

  # Bind to usbip_host driver
  $self->_write_sysfs($host_match_busid,"add ".$busid) or return;
  $self->_write_sysfs($host_bind,$busid) or return;

  return 1;
}

=head2 unbind_dev

Unbind a device from usbip_host driver. (usbip_host side)
Expects busid.

=cut

sub unbind_dev {
  my ($self,$busid) = @_;

  # Check the device is binded to usbip-host driver
  my $driver = abs_path("/sys/bus/usb/devices/".$busid."/driver") or
    ($self->{last_error} = "Can't find busid: ".$busid and return);
  unless ( $driver =~ /usbip-host/ ){
    $self->{last_error} = "busid: $busid is not binded";
    return;
  }

  # Unbind from usbip_host driver
  $self->_write_sysfs($host_unbind,$busid) or return;
  $self->_write_sysfs($host_match_busid,"del ".$busid) or return;

  # Rebind to original driver
  $self->_write_sysfs($host_rebind,$busid) or return;

  return 1;
}

=head2 export_dev

Export a device to remote system. (usbip_host side)
Expects busid and socket fd.
Outputs devid of device, which must be sent over network for the import_dev command.

=cut

sub export_dev {
  my ($self,$busid,$sock) = @_;
  my $data;

  # Check the device is binded to usbip-host driver
  my $driver = abs_path("/sys/bus/usb/devices/".$busid."/driver") or
    ($self->{last_error} = "Can't find busid: ".$busid and return);

  unless ( $driver =~ /usbip-host/ ){
    $self->{last_error} = "busid: $busid is not binded";
    return;
  }

  # Check it is available
  open my $status, '<', abs_path($host_driver.$busid.$attr_status) or
    ($self->{last_error} = "Can't find busid: ".$busid and return);
  unless ( <$status> == 1 ){
    $self->{last_error} = "busid: $busid is in use";
    return;
  }
  close $status;

  # Attach to remote
  $self->_write_sysfs(abs_path($host_driver.$busid.$attr_sockfd),$sock) or return;

  # Generate devid and speed
  open my $busnumfd, '<', abs_path($host_driver.$busid."/busnum") or
    ($self->{last_error} = "Can't find busnum for: ".$busid and return);
  open my $devnumfd, '<', abs_path($host_driver.$busid."/devnum") or
    ($self->{last_error} = "Can't find devnum for: ".$busid and return);
  open my $speedfd, '<', abs_path($host_driver.$busid."/speed") or
    ($self->{last_error} = "Can't find speed for: ".$busid and return);
  
  my $devid = oct "0b".unpack("B16",pack("n",<$busnumfd>)).unpack("B16",pack("n",<$devnumfd>));
  my $numeric_speed = <$speedfd>;

  close($busnumfd);
  close($devnumfd);
  close($speedfd);

  chomp $numeric_speed;
  my $speed = $speed_map{$numeric_speed};

  return $busid." ".$devid." ".$speed;
}

=head2 import_dev

Import a device from remote system. (usbip_vhci side)
Expects:
- export_dev's output
- socket fd
- peerhost
- peerport

=cut

sub import_dev {
  my ($self,$device_data,$sock,$peerhost,$peerport) = @_;
  my ($busid,$devid,$speed) = split (" ", $device_data);

  # Look for free port matching device speed
  my $port = $self->_get_free_port($speed);
  unless (defined $port){ $self->{last_error} = "couldn't find free port matching device speed"; return;}

  # Attach to remote
  $self->_write_sysfs($vhci_driver.$vhci_attach, $port." ".$sock." ".$devid." ".$speed) or return;
  mkdir $vhci_varrun;
  $self->_write_sysfs($vhci_varrun."port".$port, "$peerhost $peerport $busid\n") or return;

  return 1;
}

=head2 release_dev

Release an imported device. (usbip_vhci side)
Expects:
- port device is attached to

=cut

sub release_dev {
  my ($self,$port) = @_;

  # Delete status file
  unlink $vhci_varrun."port".$port or ( $self->{last_error} = "Can't delete status file: ".$vhci_varrun."port".$port and return);

  # Detach
  $self->_write_sysfs($vhci_driver.$vhci_detach, $port) or return;

  return 1;
}

=head1 INTERNAL SUBROUTINES

=head2 _write_sysfs

Write to driver's sysfs.

=cut

sub _write_sysfs {
  my ($self,$sysfs_file,$msg) = @_;

  open my $file , '>' , $sysfs_file or
    ($self->{last_error} = "Can't write to ".$sysfs_file and return);
  print $file $msg;
  close $file;

print "$sysfs_file\<\<$msg\n";
  return 1;
}

=head2 _get_free_port

Get first free port matching given speed

=cut 

sub _get_free_port {
  my ($self,$speed) = @_;
  my @files = glob($vhci_driver."status*");
  foreach my $file (@files){
    open my $fd,'<',$file or die "Can't access vhci_driver";
    while(my $line = <$fd>){
      my ($hub_speed,$port,$status, , , , ) = split(' ',$line);
      if($hub_speed eq $speed_to_string{$speed} and $status eq '004'){
        # Remove leading zeroes
        return sprintf("%d",$port);
      }
    }
  }
  return;
}

=head1 AUTHOR

Juan Antonio Zea Herranz, C<< <juan.zea at qindel.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-sys-usbip at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Linux-USBIP>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Linux::USBIP


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Linux-USBIP>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Linux-USBIP>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Linux-USBIP>

=item * Search CPAN

L<http://search.cpan.org/dist/Linux-USBIP/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2017 Juan Antonio Zea Herranz.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

1; # End of Linux::USBIP
