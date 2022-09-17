#!/usr/bin/env perl
use strict;
use warnings;

use Net::DBus qw(:typing);
use Net::DBus::Reactor;
use RRDs;

################################################################################
# configuration

use constant {
    LOG_DATA_INTERVAL => 30,
    RRD_PATH => '~/rrd/',
};

    
################################################################################
# logging

sub log_with_timestamp {
    my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time);
    printf "%04d-%02d-%02d %02d:%02d:%02d | %s\n",
	$year+1900, $mon, $mday, $hour, $min, $sec,
	join(' ', @_);
}

sub log_info {
    # comment this to disable log level INFO (normal output)
    log_with_timestamp @_;
}

sub log_other {
    # comment this to disable log level OTHER (ignored BT devices)
#    log_with_timestamp @_;
}

sub log_debug {
    # comment this to disable log level DEBUG (debug output)
#    log_with_timestamp @_;
}

sub log_dumper {
    # comment this to disable log level DUMP (use Data::Dumper on all arguments)
#    use Data::Dumper;
#    log_with_timestamp Dumper(@_);
}


################################################################################
# DBus helpers

use constant DBUS_PROPERTIES_IF => 'org.freedesktop.DBus.Properties';

my $bus = Net::DBus->system;
my $service = $bus->get_service("org.bluez");

sub register_signal {
    my ($dbus_object, $signal_name, $coderef) = @_;
    my $signal_id = $dbus_object->connect_to_signal($signal_name, $coderef);
    log_info "  registered signal $signal_name#$signal_id";
    return sub {
	log_info "  trying to unregister signal $signal_name#$signal_id";
	$dbus_object->disconnect_from_signal($signal_name, $signal_id);
	log_info "  unregistered signal $signal_name#$signal_id";
    }
}

sub unregister_signals {
    $_->() foreach reverse @_;
}

sub dbus_get_properties_if {
    my ($path) = @_;
    my $object = $service->get_object($path);
    return $object->as_interface(DBUS_PROPERTIES_IF);
}


################################################################################
# store data in RRDs

use constant RRD_DSS_CONFIG => [
    # this is no hashref, as order is important for RRDs::update!
    {
	NAME => 'temp_c',
	# LYWSD03MMC can do -9.9°C to 60°C, but give some leeway for other sensors
	MIN => -5000,
	MAX => 10000,
    },
    {
	NAME => 'hum_pc',
	MIN => 0,
	MAX => 100,
    },
    {
	NAME => 'batt_mv',
	MIN => 0,
	MAX => 5000,
    },
    {
	NAME => 'batt_pc',
	MIN => 0,
	MAX => 200, # battery level goes > 100% sometimes O_o
    },
    {
	NAME => 'rssi',
	MIN => -256,
	MAX => 0,
    },
    ];

use constant {
    RRD_HEARTBEAT => 300,
    RRD_XFF => 0.5,
    RRD_CFS => ['AVERAGE', 'MIN', 'MAX'],
    RRD_STEPS_ROWS => ['1m:1d', '15m:2w', '1h:13M', '1d:20y'],
};

sub create_rrd {
    my ($rrd_file) = @_;

    my @dss = ();
    foreach my $dss (@{RRD_DSS_CONFIG()}) {
	push @dss,
	    sprintf "DS:%s:GAUGE:%d:%d:%d",
	    $dss->{NAME}, RRD_HEARTBEAT, $dss->{MIN}, $dss->{MAX};
    }

    my @rras = ();
    foreach my $cf (@{RRD_CFS()}) {
	foreach my $steps_rows (@{RRD_STEPS_ROWS()}) {
	    push @rras,
		sprintf "RRA:%s:%s:%s",
		$cf, RRD_XFF, $steps_rows;
	}
    }

    my $step = 60;
    my @cmdline = ($rrd_file, '-s', $step, @dss, @rras);
    log_debug "RRDs::create(", @cmdline, ")";
    RRDs::create(@cmdline);
    log_info "created missing RRD file $rrd_file";
}

# RSSID and sensor data change at different times
# RSSID might be outdated, but this should not matter too much
# I don't want to handle two different RRDs because of this
# TODO: change this?  keep this?
sub store_in_rrd {
    my ($sensor) = @_;

    my $rrd_file = sprintf "%s/bt-sensors-%s.rrd", RRD_PATH, $sensor->{NAME};
    $rrd_file =~ s://+:/:g;
    $rrd_file =~ s:^~:$ENV{HOME}:e;

    create_rrd $rrd_file unless -e $rrd_file;

    my @values = map { $_ // 'U' } (
	$sensor->{TEMPERATURE_CELSIUS},
	$sensor->{HUMIDITY_PERCENT},
	$sensor->{BATTERY_MILLIVOLT},
	$sensor->{BATTERY_PERCENT},
	$sensor->{RSSI_DBM}
    );
    my @cmdline = ($rrd_file, join(':', ('N', @values)));
    log_debug "write to rrd", $rrd_file, @cmdline;
    RRDs::update(@cmdline);
}


################################################################################
# output sensor data

# FIXME: stupid name
my %known_sensors;

sub format_sensor_data {
    my ($sensor_data) = @_;

    my @values;

    my $tc = $sensor_data->{TEMPERATURE_CELSIUS};
    push @values, sprintf("T:%5.2f°C", $tc) if defined $tc;

    my $hp = $sensor_data->{HUMIDITY_PERCENT};
    push @values, sprintf("H:%5.2f%%", $hp) if defined $hp;
    
    my $bm = $sensor_data->{BATTERY_MILLIVOLT};
    push @values, sprintf("B:%4dmV", $bm) if defined $bm;
    
    my $bp = $sensor_data->{BATTERY_PERCENT};
    push @values, sprintf("B:%3d%%", $bp) if defined $bp;
    
    my $rd = $sensor_data->{RSSI_DBM};
    push @values, sprintf("S:%+2ddB/m", $rd) if defined $rd;
    
    return join ' ', @values;
}

my $print_count = 0;
sub show_sensor_data {
    if (++$print_count > LOG_DATA_INTERVAL) {
	foreach my $sensor (map { $known_sensors{$_} } sort keys %known_sensors) {
	    log_info $sensor->{NAME}, format_sensor_data($sensor);
	}
	$print_count = 0;
    }
}


################################################################################
# parse sensor data

use constant PARSERS => {
    '0000181a-0000-1000-8000-00805f9b34fb' => \&parse_LYWSD03MMC_with_ATC_MiThermometer
};

# https://github.com/atc1441/ATC_MiThermometer#advertising-format-of-the-custom-firmware
sub parse_LYWSD03MMC_with_ATC_MiThermometer {
    my ($service_data) = @_;
    my (@raw) = @{$service_data};

    return {
	TEMPERATURE_CELSIUS => ($raw[7] * 256 + $raw[8])  / 100,
	HUMIDITY_PERCENT    => $raw[9] * 2.56,
	BATTERY_PERCENT     => $raw[10],
	BATTERY_MILLIVOLT   => $raw[11] * 256 + $raw[12],
	FRAME_COUNTER       => $raw[13],
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
	log_other "ignoring added Device $name at $path";
	return;
    }
    
    log_info "found Device $name at $path:";
    log_dumper $properties;

    $known_sensors{$path}->{NAME} = $name;
    $known_devices{$path}->{NAME} = $name;

    record_device_data($path, $properties);
    
    my $properties_if = dbus_get_properties_if($path);
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
	log_other "ignoring removed Device at $path";
	return;
    }

    my $name = $device->{NAME};
    
    log_info "removed Device $name at $path:";

    # FIXME: allow calling with Array AND ArrayRef
    unregister_signals(@{$device->{SIGNALS}});

    delete $known_devices{$path};

    # FIXME remove sensor data, too?
}

sub record_device_data {
    my ($path, $properties) = @_;

    my $has_changed = 0;

    my $rssi = $properties->{RSSI};
    if (defined $rssi) {
	$known_sensors{$path}->{RSSI_DBM} = $rssi;
	# we don't bother to check if it actually has changed, just trust Bluez here
	$has_changed = 1;
    }

    my %service_data = get_device_service_data($properties);
    while (my ($service_data_uuid, $service_data) = each(%service_data)) {
	my $parser = PARSERS->{$service_data_uuid};
	next unless defined $parser;
	# FIXME: extract to merge()
	my %new_values = %{$parser->($service_data)};
	while (my ($key, $value) = each(%new_values)) {
	    $known_sensors{$path}->{$key} = $value;
	}

	# only write on sensor updates
	# TODO: write on both RSSI and sensor updates instead?
	store_in_rrd($known_sensors{$path});

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

sub adapter_set_to_power {
    my ($path) = @_;

    my $properties_if = dbus_get_properties_if($path);
    $properties_if->Set(BLUEZ_ADAPTER, 'Powered', dbus_boolean(1));
    log_info "  set to power";
}

sub adapter_start_le_discovery {
    my ($path) = @_;

    my $object = $service->get_object($path);
    my $adapter = $object->as_interface(BLUEZ_ADAPTER);
    $adapter->SetDiscoveryFilter({
	'Transport' => 'le',
	    'DuplicateData' => dbus_boolean(0),
				 });

    # FIXME: catch discovery already in progress
    $adapter->StartDiscovery;
    log_info "  discovery started";
}

sub has_changed_to_off {
    my ($changed, $property) = @_;
    # false if missing (undefined) or truthy value
    # true  if set and falsy value
    return ! ($changed->{$property} // 1);
}

sub adapter_properties_changed {
    my ($path, $changed) = @_;
    use Data::Dumper;
    print "adapter $path property change:\n" . Dumper($changed) . "\n";
    if (has_changed_to_off($changed, 'Powered')) {
	log_info("Adapter $path has lost power");
	# FIXME: setting power this will crash if the adapter has been removed
	adapter_set_to_power($path);
    }
    if (has_changed_to_off($changed, 'Discovering')) {
	log_info("Adapter $path stopped discovering");
	# FIXME: discovering will crash if the adapter has been removed
	adapter_start_le_discovery($path);
    }
}

my %known_adapters;
sub adapter_added {
    my ($path, $properties) = @_;

    log_info "found Adapter $path:";

    my $properties_if = dbus_get_properties_if($path);
    push @{$known_adapters{$path}->{SIGNALS}},
	register_signal(
	    $properties_if,
	    'PropertiesChanged',
	    sub {
		my ($interface, $changed, $invalidated) = @_;
		adapter_properties_changed($path, $changed);
	    });

    # act on current state and init adapter if needed
    adapter_properties_changed($path, $properties);
}

sub adapter_removed {
    my ($path) = @_;
    
    log_info "removed Adapter $path";
    unregister_signals(@{$known_devices{$path}->{SIGNALS}});
    delete $known_devices{$path};
}


################################################################################
# handle Bluetooth Interfaces, eg. "org/bluez/hci0"

sub interfaces_added {
    my ($path, $interfaces) = @_;

    while (my ($interface, $properties) = each(%{$interfaces})) {
	if ($interface eq BLUEZ_ADAPTER) {
	    adapter_added($path, $properties);
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

log_info "register signals for interface changes:";
my $object_manager = $service->get_object("/");
my @global_signals;
push @global_signals, register_signal($object_manager, 'InterfacesAdded', \&interfaces_added);
push @global_signals, register_signal($object_manager, 'InterfacesRemoved', \&interfaces_removed);


# do an initial scan of existing adapters
my $managed_objects = $object_manager->GetManagedObjects;
while (my ($path, $interfaces) = each %{$managed_objects}) {
    interfaces_added($path, $interfaces);
}

show_sensor_data();

# RUN IT IN THE MAIN LOOP
Net::DBus::Reactor->main->run;

# FIXME: how can we get here to clean up?
log_info "unregister all signals:";
unregister_signals(@{$known_devices{$_}->{SIGNALS}}) foreach keys %known_devices;
unregister_signals(@global_signals);
