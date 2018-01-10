package Linux::USBIP;

use 5.006;
use strict;
use warnings;
use Errno ();

use Cwd qw/abs_path/;

our $vhci_driver = "/sys/devices/platform/vhci_hcd.0";
our $vhci_varrun = "/var/run/vhci_hcd";
our $vhci_attach = "attach";
our $vhci_detach = "detach";
our $host_driver = "/sys/bus/usb/drivers/usbip-host";
our $host_bind = "$host_driver/bind";
our $host_unbind = "$host_driver/unbind";
our $host_rebind = "$host_driver/rebind";
our $host_match_busid = "$host_driver/match_busid";
our $attr_sockfd = "usbip_sockfd";
our $attr_status = "usbip_status";
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
  
  $sock->setsockopt(SOL_SOCKET,SO_REUSEADDR,1);
  $sock->setsockopt(SOL_SOCKET,SO_KEEPALIVE,1);
  
  my $usbip = Linux::USBIP->new();
  my $export_info = $usbip->export_dev($ARGV[1],fileno $sock);
  
  $export_info or die "Couldn't export device: ".$usbip->{error_msg};
  
  $sock->send($export_info);


=head1 SUBROUTINES/METHODS

=head2 new

Module constructor

=cut

sub new {
  my $self = {
               error => 0,
               error_msg => undef
             };
  return bless $self;
}

sub _clear_error {
    my $self = shift;
    $self->{error} = 0;
    $self->{error_msg} = undef;
}

sub _save_error {
    my $self = shift;
    $self->{error} = $!;
    $self->{error_msg} = join(": ", @_, "$!");
    undef;
}

sub _set_error {
    my $self = shift;
    $! = shift;
    $self->_save_error(@_);
}


=head2 bind

Bind a device to usbip_host driver. (usbip_host side)
Expects busid.

=cut

sub bind {
  my ($self,$busid) = @_;

  $self->_clear_error;

  # Don't bind hubs
  my $bDevClass_fn = "/sys/bus/usb/devices/$busid/bDeviceClass";
  open my $bDevClass , '<' , $bDevClass_fn
    or return $self->_save_error($bDevClass_fn);
  <$bDevClass> =~ /^09$/
    and return $self->_set_error(Errno::EINVAL, $bDevClass_fn, "Invalid device class");
  close $bDevClass
    or return $self->_save_error($bDevClass_fn);

  # Disconnect from driver
  my $driver_path = "/sys/bus/usb/devices/$busid/driver";
  my $driver = abs_path($driver_path)
    or return $self->save_error($driver_path);
  $driver =~ /usbip-host/
    and return $self->_set_error(Errno::EINVAL,$driver_path,"busid: $busid is already binded");
  $self->_write_sysfs($driver."/unbind",$busid) or return;

  # Bind to usbip_host driver
  $self->_write_sysfs($host_match_busid,"add ".$busid) or return;
  $self->_write_sysfs($host_bind,$busid) or return;

  return 1;
}

=head2 unbind

Unbind a device from usbip_host driver. (usbip_host side)
Expects busid.

=cut

sub unbind {
  my ($self,$busid) = @_;

  $self->_clear_error;
  # Check the device is binded to usbip-host driver
  my $driver_path = "/sys/bus/usb/devices/$busid/driver";
  my $driver = abs_path($driver_path)
    or return $self->_save_error($driver_path,"Can't find busid: ".$busid);
  $driver =~ /usbip-host$/
    or return $self->_set_error(Errno::EINVAL,"busid: $busid is not binded");

  # Unbind from usbip_host driver
  $self->_write_sysfs($host_unbind,$busid) or return;
  $self->_write_sysfs($host_match_busid,"del ".$busid) or return;

  # Rebind to original driver
  $self->_write_sysfs($host_rebind,$busid) or return;

  return 1;
}

=head2 export

Export a device to remote system. (usbip_host side)
Expects busid and socket fd.
Outputs devid of device, which must be sent over network for the import command.

=cut

sub export_dev {
  my ($self,$busid,$sock) = @_;
  my $data;

  $self->_clear_error;
  # Check the device is binded to usbip-host driver
  my $driver_fn = "/sys/bus/usb/devices/$busid/driver";
  my $driver = abs_path($driver_fn)
    or return $self->_save_error($driver_fn,"Can't find busid: ".$busid);

  $driver =~ /usbip-host/
    or return $self->_set_error(Errno::EINVAL,"busid: $busid is not binded");

  # Check it is available
  my $status_fn = "$host_driver/$busid/$attr_status";
  open my $status, '<', abs_path($status_fn)
    or return $self->_save_error($status_fn,"No status for: ".$busid);
  <$status> == 1
    or return $self->_set_error(Errno::EINVAL,$status_fn,"busid: $busid is in use");
  close $status
    or return $self->_save_error($status_fn);

  # Attach to remote
  $self->_write_sysfs(abs_path("$host_driver/$busid/$attr_sockfd"),$sock) or return;

  # Generate devid and speed
  open my $busnumfd, '<', abs_path("$host_driver/$busid/busnum")
    or return $self->_save_error("Can't find busnum for: ".$busid);
  open my $devnumfd, '<', abs_path("$host_driver/$busid/devnum")
    or return $self->_save_error("Can't find devnum for: ".$busid);
  open my $speedfd, '<', abs_path("$host_driver/$busid/speed")
    or return $self->_save_error("Can't find speed for: ".$busid);
  
  my $devid = oct "0b".unpack("B16",pack("n",<$busnumfd>)).unpack("B16",pack("n",<$devnumfd>));
  my $numeric_speed = <$speedfd>;

  close($busnumfd)
    or return $self->_save_error("$host_driver/$busid/busnum");
  close($devnumfd)
    or return $self->_save_error("$host_driver/$busid/devnum");
  close($speedfd)
    or return $self->_save_error("$host_driver/$busid/speed");

  chomp $numeric_speed;
  my $speed = $speed_map{$numeric_speed};

  return "$busid $devid $speed";
}

=head2 import

Import a device from remote system. (usbip_vhci side)
Expects:
- export's output
- socket fd
- peerhost
- peerport

=cut

sub import_dev {
  my ($self,$device_data,$sock,$peerhost,$peerport) = @_;
  my ($busid,$devid,$speed) = split (" ", $device_data);

  $self->_clear_error;
  # Look for free port matching device speed
  my $port = $self->_get_free_port($speed);
  defined $port
    or return $self->_set_error(Errno::EINVAL,"couldn't find free port matching device speed");

  # Attach to remote
  $self->_write_sysfs("$vhci_driver/$vhci_attach", "$port $sock $devid $speed") or return;
  mkdir $vhci_varrun;
  $self->_write_sysfs("$vhci_varrun/port$port", "$peerhost $peerport $busid\n") or return;

  return 1;
}

=head2 release

Release an imported device. (usbip_vhci side)
Expects:
- port device is attached to

=cut

sub release {
  my ($self,$port) = @_;

  $self->_clear_error;
  # Delete status file
  unlink "$vhci_varrun/port$port"
    or return $self->_save_error("Can't delete status file: ".$vhci_varrun."/port".$port);

  # Detach
  $self->_write_sysfs("$vhci_driver/$vhci_detach", $port) or return;

  return 1;
}

=head1 INTERNAL SUBROUTINES

=head2 _write_sysfs

Write to driver's sysfs.

=cut

sub _write_sysfs {
  my ($self,$sysfs_file,$msg) = @_;

  open my $file , '>' , $sysfs_file
    or return $self->_save_error($sysfs_file);
  print $file $msg
    or return $self->_save_error($sysfs_file);
  close $file
    or return $self->_save_error($sysfs_file);

print "$sysfs_file\<\<$msg\n";

  return 1;
}

=head2 _get_free_port

Get first free port matching given speed

=cut 

sub _get_free_port {
  my ($self,$speed) = @_;
  my @files = glob($vhci_driver."/status*");
  foreach my $file (@files){
    open my $fd,'<',$file
      or return $self->_save_error($file,"Can't access vhci_driver");
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
