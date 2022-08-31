# simple data logger for Xiaomi LYWSD03MMC BLE sensors

project page: https://github.com/mmitch/bt-sensors-rrd

This is my first go at both Bluetooth and DBus, be lenient.

## dependencies

- Perl
  - Net::Dbus
  - RRDs

- a Bluetooth adapter in your system supporting BLE (Bluetooth Low Energy)
- bluez+dbus

- a Xiaomi LYWSD03MMC BLE sensor
  - flashed with alternative firmware from https://github.com/pvvx/ATC_MiThermometer

## operation

Just start `dbus-bt-listener.pl`.

The script will then

1. connect to Bluez over DBus
2. detect all your Bluetooth adapters
3. instruct all of them to go into `lescan` mode (passive discovery of low energy devices)
4. when one of the Xiaomi devices is found, callbacks for property changes on the devices are registered
5. received property changes are written to a simple RRD (round robin database)

The alternative firmware on the sensors makes them send an unconditional announcement every 60 seconds.
The announcement packet already contains the sensor data (temperature, humidity, battery level).
Bluez will receive the announcement packets and pass them on to our script as a PropertyChanged event.

There is no need for any pairing of Bluetooth devices which means a longer lasting battery on the sensors.
