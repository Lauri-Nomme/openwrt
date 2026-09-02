#!/bin/sh
# Apply TFTP/initramfs-only network overrides for the BPI-R4 Pro 8X.
#
# When running from an initramfs (e.g. booted via TFTP or the recovery
# image), the user's ISP cable is plugged into a 2.5G MxL switch port
# (lan3), NOT the 10G WAN combo. Configure WAN on lan3 so the router is
# usable immediately during recovery/testing sessions.
#
# This must NOT affect a normal install booted from NAND or eMMC: those
# keep the stock default (WAN on the 10G combo port `wan`).
#
# Detection: an initramfs boot has root on tmpfs, while a flashed boot
# mounts squashfs/ubifs for /rom and /overlay.

[ -e /etc/board.d/00_network ] && exit 0
. /lib/functions/system.sh

[ "$(board_name)" = "bananapi,bpi-r4-pro-8x" ] || exit 0

# bail out if NOT initramfs (already running from flash)
mount | grep -qE " on / type tmpfs" || exit 0

# Verify the expected fallback port exists before reconfiguring
[ -e /sys/class/net/lan3 ] || exit 0

# Remove the default wan (10G combo) configs, set WAN on the lan3 2.5G
# port, pin the LAN bridge to 10.222.1.2 and rebuild its port list.
uci -q batch <<-EOF
	delete network.wan
	delete network.wan6
	set network.wan=interface
	set network.wan.device='lan3'
	set network.wan.proto='dhcp'
	set network.wan6=interface
	set network.wan6.device='lan3'
	set network.wan6.proto='dhcpv6'
	set network.lan.ipaddr='10.222.1.2'
	set network.lan.netmask='255.255.255.0'
	commit network
EOF

# make sure lan3 is in the LAN bridge's exclusion set
uci set network.@device[0].ports='lan1 lan2 lan4 lan5'
uci commit network

exit 0