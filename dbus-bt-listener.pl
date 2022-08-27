#!/usr/bin/env perl
use strict;
use warnings;

use Net::DBus qw(:typing);
use Net::DBus::Reactor;

use Data::Dumper;

my $bus = Net::DBus->system;
my $service = $bus->get_service("org.bluez");

################################################################################
# DBus helpers

sub register_signal {
    my ($dbus_object, $signal_name, $coderef) = @_;
    my $signal_id = $dbus_object->connect_to_signal($signal_name, $coderef);
    print "  registered signal $signal_name#$signal_id\n";
    return sub {
	$dbus_object->disconnect_from_signal($signal_name, $signal_id);
	print "  unregistered signal $signal_name#$signal_id\n";
    }
}

sub unregister_signals {
    $_->() foreach reverse @_;
}


################################################################################
# output sensor data

# FIXME: stupid name
my %known_sensors;

sub print_row {
    my (@data) = @_;
    @data = map { sprintf "%-48s", $_ } @data;
    print join('  |  ', @data) . "\n";
}

sub format_sensor_data {
    my ($sensor_data) = @_;

    my @values;

    my $tc = $sensor_data->{TEMPERATURE_CELSIUS};
    push @values, sprintf("T:%5.2fC", $tc) if defined $tc;

    my $hp = $sensor_data->{HUMIDITY_PERCENT};
    push @values, sprintf("H:%5.2f%%", $hp) if defined $hp;
    
    my $bm = $sensor_data->{BATTERY_MILLIVOLT};
    push @values, sprintf("B:%4dmV", $bm) if defined $bm;
    
    my $bp = $sensor_data->{BATTERY_PERCENT};
    push @values, sprintf("B:%2d%%", $bp) if defined $bp;
    
    my $rd = $sensor_data->{RSSI_DBM};
    push @values, sprintf("S:%+2ddB/m", $rd) if defined $rd;
    
    return join ' ', @values;
}

my $print_count = 0;
sub show_sensor_data {
    if (++$print_count > 30) {
	print "\n" . localtime(time()) . "\n";
	print_row map { (split m:/:, $_)[-1]  } sort keys %known_sensors;
	$print_count = 0;
	print_row map { format_sensor_data($known_sensors{$_}) } sort keys %known_sensors;
	print "\n";
    }
}


################################################################################
# parse sensor data

use constant PARSERS => {
    '0000181a-0000-1000-8000-00805f9b34fb' => \&parse_YMCA_with_ATC_firmare_type_x
};

# https://github.com/pvvx/ATC_MiThermometer
sub parse_YMCA_with_ATC_firmare_type_x {
    my ($service_data) = @_;
    my (@raw) = @{$service_data};

    return {
	TEMPERATURE_CELSIUS => ($raw[7] * 256 + $raw[8]) / 100,
	HUMIDITY_PERCENT    => ($raw[9] * 256 + $raw[10]) / 100,
	BATTERY_MILLIVOLT   => $raw[11] * 256 + $raw[12],
	BATTERY_PERCENT     => $raw[13],
    }
}
    

################################################################################
# handle Bluetooth Devices, that is: our sensors (ignoring everything else)

# DBus interface for Devices
use constant BLUEZ_DEVICE => 'org.bluez.Device1';

my %known_devices;

sub get_device_name {
    my ($properties) = @_;
    return $properties->{Name} // '**null**';
}

sub get_device_service_data {
    my ($properties) = @_;
    return %{$properties->{ServiceData} // {}};
}

sub is_device_a_supported_sensor {
    my ($properties) = @_;
    my %service_data = get_device_service_data($properties);
    # Fixme: use grep/map
    foreach my $service_data_uuid (keys %service_data) {
	return 1 if exists PARSERS->{$service_data_uuid}
    }
    return 0;
}

sub device_added {
    my ($path, $properties) = @_;

    my $name = get_device_name($properties);
    if (!is_device_a_supported_sensor($properties)) {
	print "\nignoring added Device $name at $path\n";
	return;
    }
    
    print "\nfound Device $name at $path:\n";
    # print Dumper($properties);
    # print "  supported interfaces: " . join(', ', @interface_names) . "\n";

    record_device_data($path, $properties);
    
    my $object = $service->get_object($path);
    my $properties_if = $object->as_interface('org.freedesktop.DBus.Properties');

    $known_devices{$path}->{NAME} = $name;
    
    push @{$known_devices{$path}->{SIGNALS}},
	register_signal(
	    $properties_if,
	    'PropertiesChanged',
	    sub {
		my ($interface, $changed, $invalidated) = @_;
		device_properties_changed($path, $changed);
	    });
}

sub device_removed {
    my ($path) = @_;

    my $device = $known_devices{$path};

    unless (defined $device) {
	print "\nignoring removed Device at $path\n";
	return;
    }

    my $name = $device->{NAME};
    
    print "\nremoved Device $name at $path:\n";

    # FIXME: allow calling with Array AND ArrayRef
    unregister_signals(@{$device->{SIGNALS}});

    delete $known_devices{$path};

    # FIXME remove sensor data, too?
}

sub record_device_data {
    my ($path, $properties) = @_;

    my $has_changed = 0;

    my %service_data = get_device_service_data($properties);
    while (my ($service_data_uuid, $service_data) = each(%service_data)) {
	my $parser = PARSERS->{$service_data_uuid};
	next unless defined $parser;
	# FIXME: extract to merge()
	my %new_values = %{$parser->($service_data)};
	while (my ($key, $value) = each(%new_values)) {
	    $known_sensors{$path}->{$key} = $value;
	}
	$has_changed = 1;
    }

    my $rssi = $properties->{RSSI};
    if (defined $rssi) {
	$known_sensors{$path}->{RSSI_DBM} = $rssi;
	# we don't bother to check if it actually has changed, just trust Bluez here
	$has_changed = 1;
    }

    return $has_changed;
}

sub device_properties_changed {
    my ($path, $changed) = @_;
    if (record_device_data($path, $changed)) {
	show_sensor_data();
    }
}


################################################################################
# handle Bluetooth Adapters aka. "our network devices" (eg. Bluetooth USB stick)

# DBus interface for Adapters
use constant BLUEZ_ADAPTER => 'org.bluez.Adapter1';

sub adapter_added {
    my ($path) = @_;
    
    print "\nfound Adapter $path:\n";
    # print Dumper($properties);
    
    my $object = $service->get_object($path);
    my $properties = $object->as_interface('org.freedesktop.DBus.Properties');
    $properties->Set(BLUEZ_ADAPTER, 'Powered', dbus_boolean(1));
    print "  set to power\n";

    # start BLE discovery
    my $adapter = $object->as_interface(BLUEZ_ADAPTER);
    $adapter->SetDiscoveryFilter({
	'Transport' => 'le',
	    'DuplicateData' => dbus_boolean(0),
				 });

    # FIXME: catch discovery already in progress
    $adapter->StartDiscovery;
    print "  discovery started\n";
}

sub adapter_removed {
    my ($path) = @_;
    
    print "\nremoved Adapter $path\n";
}


################################################################################
# handle Bluetooth Interfaces, eg. "org/bluez/hci0"

sub interfaces_added {
    my ($path, $interfaces) = @_;

    while (my ($interface, $properties) = each(%{$interfaces})) {
	if ($interface eq BLUEZ_ADAPTER) {
	    adapter_added($path);
	}
	elsif ($interface eq BLUEZ_DEVICE) {
	    device_added($path, $properties);
	}
    }
}

sub interfaces_removed {
    my ($path, $interfaces) = @_;

    foreach my $interface (@{$interfaces}) {
	if ($interface eq BLUEZ_ADAPTER) {
	    adapter_removed($path);
	}
	elsif ($interface eq BLUEZ_DEVICE) {
	    device_removed($path);
	}
    }
}


################################################################################
# main routine

print "register signals for interface changes:\n";
my $object_manager = $service->get_object("/");
my @global_signals;
push @global_signals, register_signal($object_manager, 'InterfacesAdded', \&interfaces_added);
push @global_signals, register_signal($object_manager, 'InterfacesRemoved', \&interfaces_removed);


# do an initial scan of existing adapters
my $managed_objects = $object_manager->GetManagedObjects;
while (my ($path, $interfaces) = each %{$managed_objects}) {
    interfaces_added($path, $interfaces);
}

print "\n\n";
show_sensor_data();

# RUN IT IN THE MAIN LOOP
Net::DBus::Reactor->main->run;

# FIXME: how can we get here to clean up?
print "unregister all signals:\n";
unregister_signals(@{$known_devices{$_}->{SIGNALS}}) foreach keys %known_devices;
unregister_signals(@global_signals);
