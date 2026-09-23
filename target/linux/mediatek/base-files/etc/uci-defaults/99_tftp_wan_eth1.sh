#!/bin/sh
# Apply TFTP/initramfs-only network overrides for the BPI-R4 Pro 8X.
#
# WAN on this board is the 10G combo port `eth1` (gmac1 / usxgmii, as21xxx
# PHY). That is true in every boot mode, including recovery/TFTP, so the
# override below only pins WAN explicitly to eth1 and sets the LAN address;
# it must never move WAN to a switch port.
#
# This fires ONLY for an initramfs boot (TFTP/recovery). A flashed
# NAND/eMMC boot keeps the stock default config untouched.
#
# Detection: an initramfs boot has root on tmpfs, while a flashed boot
# mounts squashfs/ubifs for /rom and /overlay.
#
# NOTE: do not gate on DSA user ports (`/sys/class/net/lanX`) existing.
# uci-defaults run from /etc/init.d/boot (S10boot) long before the
# MxL/mt7530 switches probe and create lan1..lan6 (observed: init at 12.4s,
# lan3 netdev at 38.4s). The config is plain UCI and does not need the
# netdev; netifd picks it up when the ports appear.

. /lib/functions/system.sh

[ "$(board_name)" = "bananapi,bpi-r4-pro-8x" ] || exit 0

# bail out if NOT initramfs (already running from flash)
mount | grep -qE " on / type tmpfs" || exit 0

# WAN is eth1 in all boot modes; make it explicit rather than relying on
# whatever the recovery image default happens to be, and pin the LAN addr.
uci -q batch <<-EOF
	set network.wan=interface
	set network.wan.device='eth1'
	set network.wan.proto='dhcp'
	set network.wan6=interface
	set network.wan6.device='eth1'
	set network.wan6.proto='dhcpv6'
	set network.lan.ipaddr='10.222.1.2'
	set network.lan.netmask='255.255.255.0'
	commit network
EOF

exit 0
