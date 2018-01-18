package Linux::USBIP;

our $VERSION = '0.01';

use 5.010;
use strict;
use warnings;
use Errno ();
use Carp;

use Cwd qw(abs_path);

our $debug //= 0;
sub _debug {
    $debug or return;
    my $msg = "@_\n";
    local $!;
    warn $msg;
}

# Those mappings have been extracted from the USB/IP tools source code:

our %speed2int = ( '1.5'     => '1',
                   '12'      => '2',
                   '480'     => '3',
                   '5000'    => '5',
                   '10000'   => '6',
                   'unknown' => '0'
                 );

our %int2hub_speed = (
                  '1' => 'hs',
                  '2' => 'hs',
                  '3' => 'hs',
                  '5' => 'ss',
                  '6' => 'ss',
                  '0' => 'hs'
);

sub new {
  my ($class, %opts) = @_;

  my $sysfs_root = delete $opts{sysfs_root} // '/sys';
  $sysfs_root =~ s|(?<=.)/+||; # remove any trailing slashes
  $sysfs_root =~ /^\// or croak "sysfs_root must point to an absolute directory";

  my $run_path = $opts{run_path} // '/var/run/vhci_hcd';
  $run_path =~ s|(?<=.)/+||;

  my $self = { sysfs_root => $sysfs_root,
               run_path => $run_path,
               platform_path => "$sysfs_root/devices/platform",
               drivers_path =>"$sysfs_root/bus/usb/drivers",
               drivers_usbip_host_path => "$sysfs_root/bus/usb/drivers/usbip-host",
               devices_path => "$sysfs_root/bus/usb/devices",
             };

  bless $self, $class;
  $self->_clear_error;

  return $self;
}

sub _clear_error {
  my $self = shift;
  $self->{error} = 0;
  $self->{error_msg} = undef;
  1;
}

sub _save_error {
  my $self = shift;
  $self->{error} = $!;
  $self->{error_msg} = join(": ", @_, "$!");
  _debug("_save_error($!, $self->{error_msg})");
  ()
}

sub _set_error {
  my $self = shift;
  $! = shift;
  $self->_save_error(@_);
}

sub bind {
  my ($self, $busid) = @_;

  $self->_clear_error;
  my $usbip_host_path = $self->_realpath("$self->{drivers_path}/usbip-host") // return;

  # Don't bind hubs
  my $devclass_path = "$self->{devices_path}/$busid/bDeviceClass";
  my $devclass = $self->_file_get_line($devclass_path) // return;
  $devclass eq '09'
    and return $self->_set_error(Errno::EINVAL, $devclass_path, "Invalid device class $devclass for device $busid");

  # Disconnect from driver
  my $driver_path = "$self->{devices_path}/$busid/driver" // return;
  my $driver_realpath = $self->_realpath($driver_path) // return;

  # Commenting out the following code because, well, it was already binded, and so what?
  # $driver_realpath eq $usbip_host_path
  #   and return $self->_set_error(Errno::EINVAL, $driver_path, "Device $busid already binded");

  $self->_file_atomic_put("$driver_path/unbind", $busid) // return;
  $self->_file_atomic_put("$usbip_host_path/match_busid", "add $busid")
    and $self->_file_atomic_put("$usbip_host_path/bind", $busid)
    and return 1;

  # On failure try to revert the unbind
  _debug("Unable to bind $busid to usbip_host driver, ",
         "reverting to old driver at $driver_realpath");
  local ($!, @{$self}{qw(error error_msg)});
  $self->_file_atomic_put("$driver_realpath/bind", $busid);
}

sub unbind {
  my ($self, $busid) = @_;

  $self->_clear_error;
  my $usbip_host_path = $self->_realpath("$self->{drivers_path}/usbip-host") // return;

  # Check the device is binded to usbip-host driver
  my $driver_path = "$self->{devices_path}/$busid/driver";
  my $driver_realpath = $self->_realpath($driver_path) // return;

  $driver_realpath eq $usbip_host_path
    or return $self->_set_error(Errno::EINVAL, $driver_path, "Device $busid is not binded to usbip-host driver");

  $self->_file_atomic_put("$usbip_host_path/unbind", $busid)
    and $self->_file_atomic_put("$usbip_host_path/match_busid", "del $busid")
    and $self->_file_atomic_put("$usbip_host_path/rebind", $busid);
}

sub _sock2fd {
  my ($self, $sock) = @_;

  local $@;
  if (defined (my $fd = eval { fileno $sock })) {
    return $fd if $fd >= 0;
  }
  else {
    return $1 if $sock =~ /^(\d+)$/;
  }
  croak "The given value is not a file handle or file descriptor number";
}

sub export {
  my ($self, $busid, $sock) = @_;
  $self->_clear_error;

  my $sockfd = $self->_sock2fd($sock);
  my $usbip_host_path = $self->_realpath("$self->{drivers_path}/usbip-host") // return;

  # Check the device is binded to usbip-host driver
  my $driver_path = "$self->{devices_path}/$busid/driver";
  my $driver_realpath = $self->_realpath($driver_path) // return;

  $driver_realpath eq $usbip_host_path
    or return $self->_set_error(Errno::EINVAL, $driver_path,
                                "Device $busid is not binded to usbip-host driver");

  # Check it is available
  my $status_path = "$usbip_host_path/$busid/usbip_status";
  my $status = $self->_file_get_line($status_path) // return;
  $status == 1 or return $self->_set_error(Errno::EBUSY, $status_path,
                                           "Device $busid is already in use");

  # Attach to remote
  $self->_file_atomic_put("$usbip_host_path/$busid/usbip_sockfd", $sockfd) // return;

  my $busnum = $self->_file_get_line("$usbip_host_path/$busid/busnum") // return;
  my $devnum = $self->_file_get_line("$usbip_host_path/$busid/devnum") // return;

  my $devid = ($busnum << 16) + $devnum;

  my $speed = $self->_file_get_line("$usbip_host_path/$busid/speed") // return;
  my $numeric_speed = $speed2int{$speed} // 0;

  wantarray ? ($devid, $numeric_speed) : "$devid $numeric_speed";
}

*export_dev = \&export;

sub attach {
  my ($self, $sock, $devid, $speed, $vhci) = @_;
  $self->_clear_error;

  my $sock_fd = $self->_sock2fd($sock);
  my $vhci_prefix = "$self->{platform_path}/vhci_hcd";
  my $new_version = not -f "$vhci_prefix.0/status.1";

  my @ixs;
  if (defined $vhci) {
    $vhci =~ /^\d+$/ or croak "Invalid VHCI index";
    @ixs = $vhci;
  }
  else {
    opendir my $dh, $self->{platform_path}
      or return $self->_save_error($self->{platform_path});
    while (defined (my $dir = readdir $dh)) {
      push @ixs, $1 if $dir =~ /^vhci_hcd\.(\d+)$/;
    }
    closedir $dh;
  }

  my ($attach_fh, $attach_path, $vhci_path, $last_path);
  unless ($new_version) {
    $vhci_path = "$vhci_prefix.0";
    $attach_path = "$vhci_path/attach";
    open $attach_fh, '>', $attach_path
      or return $self->_save_error($attach_path)
  }

  # Errors when opening files are ignored in the following code
  # because those are normal under certain sysfs configurations.
  for my $ix (@ixs) {
    my $status_path;
    if ($new_version) {
      $vhci_path = "$vhci_prefix.$ix";
      $status_path = "$vhci_path/status";
      $attach_path = "$vhci_path/attach";
      close $attach_path if defined $attach_path;
      open $attach_fh, '>', $attach_path or next;
    }
    else {
      $status_path = "$vhci_path/status" . ($ix ? ".$ix" : '');
    }
    $last_path = $status_path;

    my $expected_hub = (($speed == 5 or $speed == 6) ? 'ss' : 'hs');

    if (open my $fh, '<', $status_path) {
      my $offset;
      scalar <$fh>; # discard header
      while (<$fh>) {
        my ($hub, $port, $sta) = split /\s+/, $_;
        $port = int $port; $sta = int $sta;
        $offset //= $port;
        if ($hub eq $expected_hub and $sta == 4) {
          if (__atomic_syswrite($attach_fh, "$port $sock_fd $devid $speed\n")) {
            my $effective_ix = ($new_version ? $ix : 0);
            return (wantarray ? ($effective_ix, $port) : "$effective_ix-$port")
          }
          else {
            redo if $! == Errno::EINTR;
            next if $! == Errno::EBUSY;
            return $self->_save_error($attach_path);
          }
        }
      }
    }
  }
  $self->_set_error(Errno::ENOSPC, $last_path, "Unable to find an unused USB/IP port");
}

*import_dev = \&attach;

sub save_port_data {
  my ($self, $ix, $port, $peerhost, $peerport, $peerbusid) = @_;
  $self->_clear_error;

  my $new_version = not -f "$self->{platform_path}/vhci_hcd.0/status.1";
  my $run_path = $self->{run_path};
  $_ //= '-' for ($peerhost, $peerport, $peerbusid);
  $self->_ensure_dir($run_path)
    and $self->_file_atomic_put("$run_path/port" . ($new_version ? "$ix-$port" : $port),
                                "$peerhost $peerport $peerbusid\n")
}

sub detach {
  my ($self, $ix, $port) = @_;
  $self->_clear_error;

  my $vhci_prefix = "$self->{platform_path}/vhci_hcd";
  my $new_version = not -f "$vhci_prefix.0/status.1";
  $self->_file_atomic_put(($new_version
                           ? "$vhci_prefix.$ix/detach"
                           : "$vhci_prefix.0/detach"),
                          $port)
}

*release = \&detach;


sub rm_port_data {
  my ($self, $ix, $port) = @_;
  $self->_clear_error;

  my $run_path = $self->{run_path};
  my @paths = "$run_path/port$ix-$port";
  push @paths, "$run_path/port$port" if $ix == 0;

  for (@paths) {
    if (-f $_) {
      unlink $_
        or return $self->_save_error($_);
    }
  }
  return 1;
}

sub _ensure_dir {
  my ($self, $path) = @_;
  if (-d $path) {
    _debug("Directory $path already exists");
    return 1;
  }
  if (mkdir $path) {
    _debug("Directory $path created");
    return 1;
  }
  _debug("Unable to create directory at $path");
  $self->_save_error($path);
}

sub __atomic_syswrite {
  my $fh = shift;
  for (1) {
    my $bytes = syswrite($fh, $_[0]);
    if (defined $bytes) {
      return 1 if $bytes == length $_[0];
      _debug("__atomic_syswrite failed: not all data was actually written, " .
             "msg length: ".length($_[0]).", bytes written: $bytes");
      $! = Errno::EBADE;
    }
    redo if $! == Errno::EINTR;
  }
  _debug("__atomic_syswrite failed: $!");
  ()
}

sub _file_atomic_put {
  my ($self, $path, $msg) = @_;
  my $fh;
  if (open $fh , '>' , $path) {
    if (__atomic_syswrite($fh, $msg)) {
      if (close $fh) {
        return 1;
      }
      _debug("Unable to close file $path: $!");
    }
    _debug("Unable to write data to $path: $!");
  }
  else {
    _debug("Unable to open file $path: $!");
  }
  $self->_save_error($path);
}

sub _file_get_line {
  my ($self, $path) = @_;
  if (open my $fh, '<', $path) {
    my $data = <$fh> // '';
    if (close $fh) {
      chomp $data;
      _debug("Data read from $path: $data");
      return $data;
    }
    else {
      _debug("Unable to close file $path after reading: $!");
    }
  }
  else {
    _debug("Unable to open file $path for reading: $!");
  }
  $self->_save_error($path);
}

sub _file_get {
  my $self = shift;
  undef $/;
  $self->_file_get_line(@_)
}

sub _realpath {
  my ($self, $path) = @_;
  if (defined(my $abs_path = abs_path($path))) {
    return $abs_path;
  }
  _debug("_realpath($path) failed");
  $self->_save_error($path)
}

1;

__END__


=head1 NAME

Linux::USBIP - Manage Linux USB/IP ports and connections.

=head1 SYNOPSIS

  use v5.10;
  use Linux::USBIP;

  my $usbip = Linux::USBIP->new();


  # On the host where the physical USB devices are attached...

  # Bind some device to the usbip_host driver so that it can be
  # exported using USB/IP:
  $usbip->bind('3-6') // die $!;

  # Connect the device to a socket:
  my $sock = ...
  $usbip->export('3-6', $sock) // die $!;

  # Kill the ongoing USB/IP connection
  $usbip->release('3-6') // die $!;

  # Unbind it
  $usbip->unbind('3-6') // die $!;


  # Now, on the other host where we want to use the remote devices...

  # Attach a remote USB device:
  my $sock = ...;
  my ($vix, $port) = $usbip->attach($sock, $peer_dev_id, $speed) // die $!;

  # Optionally, save the info so that it can be seen by the USB/IP utils:
  $usbip->save_port_data($vix, $port,
                         $peerhost, $peerport, $peerbusid) // die $!;

  # Detach the device once you have finished using it:
  $usbip->detach($vix, $port) // die $!;

  # Optionally, remove its peer data:
  $usbip->rm_port_data($vix, $port);


=head1 DESCRIPTION

Provides access to Linux kernel's usbip functions.
Different from usbip tool included with kernel sources. It doesn't have
a server function. This tool dependes on you creating a tcp socket on
both sides, so you choose which side is server and client.

=head1 API

=head2 Common methods

=over 4

=item $usbip = Linux::USBIP->new(%opts)

Object constructor.

The following options are accepted:

=over 4

=item sysfs_root => $path

C<sysfs> mount point. Defaults to C</sys>.

=item run_path => $path

Directory to save remote USBIP port data. Defaults to
C</var/run/vhci_hcd> (as used by the USB/IP tools).

=back

=back

=head2 C<usbip_host> side methods

The following are the methods for interacting with the C<usbip_host>
side (the one where the real physical devices are attached).

=over 4

=item $usbip->bind($busid)

Binds a device to the C<usbip_host> driver.

=item $usbip->unbind($busid)

Unbinds a device from the C<usbip_host> driver so that it can be used
by the local drivers and applications again.

=item $usbip->export($busid, $sock_or_fd)

Connects the given socket to the USB device with the given busid.

The device must have been previously bound to the C<usbip_host> driver
using the L<bind> method.

=back

=head2 C<vhci_hcd> side methods

=over 4

=item $usbip->attach($sock, $devid, $speed, $vhci_ix)

Attachs a remote device into the host.

The C<$vhci_ix> argument is optional. When not given, this method will
look for free ports in all the vhcis.

=item $usbip->save_port_data($vhci_ix, $port, $peerhost, $peerport, $peerbusid)

Saves the given data into a file under C</var/run/vhci_hcd>.

Those files are consulted by the USB/IP tools in order to provide
information to the user about the current active connections.

=item $usbip->detach($vhci_ix, $port)

Releases a previously attached device.

=item $usbip->rm_port_data($ix, $port)

Removes the file in C</var/run/vhci_hcd> containing the port data.

=back

=head1 AUTHORS

Juan Antonio Zea Herranz, C<< <juan.zea at qindel.com> >>

Salvador Fandiño C<< <salvador@qindel.com> >>

=head1 BUGS AND SUPPORT

Please report any bugs or feature requests using the
 L<https://github.com/theqvd/p5-Linux-USBIP/issues|GitHub bug tracker>.

=head1 LICENSE AND COPYRIGHT

Copyright 207-2018 Qindel FormaciE<oacute>n y Servicios, S.L.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see L<http://www.gnu.org/licenses/>.

=cut

