# Migration guide: retain configuration from stock BPI image

This document covers moving your configuration from the **stock BPI image**
(OpenWrt 24.10-SNAPSHOT, kernel 6.6.93, **opkg**) to the **custom image**
built from this fork (OpenWrt main, kernel 6.18.44, **apk**).

> **Summary:** most UCI configs (`/etc/config/*`) port over cleanly, but the
> **network topology must be rewritten** (kernel port names changed), and the
> **package manager changed** (opkg → apk), so packages must be reinstalled
> rather than migrated. WiFi/firewall/collectd/dropbear all carry over.

---

## 1. What to back up (from the running stock Banana)

```sh
# On the current (stock) device:
tar -C / -czf /tmp/config-backup.tar.gz \
    etc/config \
    etc/passwd etc/shadow etc/group \
    etc/dropbear \
    etc/firewall.user \
    etc/rc.local \
    etc/hostname \
    etc/uhttpd* \
    root/.ssh root/.config root/bla.sh root/fixeth1.sh root/pwm.sh root/working
# copy off:
scp root@10.222.1.2:/tmp/config-backup.tar.gz .
```

The user-specific items on this Banana:

| Item | Path | Notes |
|---|---|---|
| UCI configs | `/etc/config/*` | network, wireless, dhcp, firewall, system, dropbear, uhttpd, luci, collectd, ksmbd, upnpd, omcproxy, mtkhnat |
| SSH/authorized keys | `/etc/dropbear/`, `/root/.ssh/` | host key + your login keys |
| User scripts | `/root/bla.sh`, `/root/fixeth1.sh`, `/root/pwm.sh`, `/root/working` | manual tuning (ethtool autoneg, fan PWM) |
| Collectd data | `/tmp/rrd/banana` | **not persistent** (tmpfs) — history is lost on reboot anyway |
| Package list | `opkg list-installed` | see §4 |

## 2. How to transfer config to the new image

### Option A — sysupgrade keeps config (cleanest)
If you flash via the custom image's `*-squashfs-sysupgrade.itb`, sysupgrade
will try to keep `/etc/config/*` automatically (no `-n` flag). **However**:

- The network config will be **wrong** (port names changed, see §3) → you'd
  lose connectivity and must fix via serial console.
- opkg-installed packages are **not** carried over.

**Recommended:** first do a config backup (above), flash, then restore the
network section manually (below).

### Option B — manual restore onto a fresh SD/eMMC install
Boot the new image (e.g. from SD), then:

```sh
# 1. restore configs (network will need fixing, see §3)
tar -C / -xzf /tmp/config-backup.tar.gz

# 2. restore SSH keys (keeps your existing login working)
cp -a /root/.ssh/* /etc/dropbear/ 2>/dev/null   # id_dropbear etc.

# 3. restart config-dependent services
/etc/init.d/dropbear restart
/etc/init.d/network restart
/etc/init.d/firewall restart
```

## 3. Network config — MUST be rewritten

The kernel changed the switch port naming (stock `mxl_lan0-3`, `lan0`, `lan3`,
`eth1` → new DSA naming `lan1..lan6`, `wan`, `sfp-wan`). **The old
`/etc/config/network` will not work as-is.**

The custom image's default topology (`target/linux/mediatek/filogic/base-files/etc/board.d/02_network`):

```
bananapi,bpi-r4-pro-8x)  LAN: lan1 lan2 lan3 lan4 lan5 lan6   WAN: wan
```

New default mapping (single LAN bridge over all ports + wan on the WAN 10G port):

| Stock name (old) | New name (custom image) |
|---|---|
| `mxl_lan0`..`mxl_lan3` | `lan1`..`lan4` (2.5G, MxL switch) |
| `lan3` (1G) | `lan5` |
| 10G LAN combo (copper) | `lan6` |
| `lan0` + `eth1` (wan bridge) | `wan` (10G WAN combo, copper default) |
| — | `sfp-wan` (if wan-sfp overlay selected) |

To replicate your current setup (LAN bridge over most ports + DHCP WAN),
start from the image defaults and edit `/etc/config/network`:

```
# your 10.222.1.2 static LAN is preserved if you keep the default br-lan,
# just change the IP:
uci set network.lan.ipaddr='10.222.1.2'
uci commit network
```

If you need the LAN/WAN bridging exactly as before, set `br-lan` ports to
`lan1 lan2 lan3 lan4 lan5 lan6` and keep `wan` as the DHCP WAN interface.
(Note: your stock config had a **static route** to `10.222.20.0/24` via
`10.222.1.1` — re-add it if still needed.)

## 4. Packages — reinstall, don't migrate

- **Stock image:** opkg. **Custom image:** apk (`CONFIG_USE_APK=y`).
- Installed packages are NOT carried over by sysupgrade or a tar restore.
- The custom image already **bakes in** the package set that was installed
  on this Banana (luci, collectd, ksmbd, iperf3, etc. — see `config.seed`),
  so after flashing, most things are already present.
- To verify / reinstall anything extra from the new apk feed:

```sh
apk update
apk add <package>          # e.g. any package not in the baked-in set
```

- BPI/MTK-proprietary packages (`mii_mgr`, `mtkhnat_util`, `netsys_dbg_util`,
  `mtk_factory_rw`, `smp_util`, `ethswbox`, `atenl`, `ephy-utils`, `afcd`,
  `regs`, `switch`) are **not available** in the custom image (mainline-only).
  If you relied on `mtkhnat` hardware offload, mainline uses the upstream
  PPE/flow offload instead (already enabled).

## 5. WiFi config

`/etc/config/wireless` should carry over as-is:

- Same card (MT7996E), same radio paths (`soc/11300000.pcie/...`).
- Your `banaiot` (2.4G) and `banana5ax` (5G EHT80) SSIDs/keys are retained.
- The `radio2` disabled 5G radio and the `ap_mld_1` MLD section carry over too.
- `wpad` backend differs (stock `wpad-openssl` vs custom `wpad-basic-mbedtls`)
  — fine for WPA2/WPA3-Personal; switch to `wpad-openssl` only if you need
  WPA3-Enterprise.

## 6. Other configs that carry over

- **firewall** (`/etc/config/firewall`) — yes, mostly compatible.
- **collectd / luci_statistics** — config yes; **historical RRD data no**
  (it lived in tmpfs `/tmp/rrd` and is gone on reboot anyway).
- **dropbear** — config + keys carry over (restore `/etc/dropbear`).
- **ksmbd** — config carries over.
- **upnpd / omcproxy** — config carries over.
- **mtkhnat config** — the `/etc/config/mtkhnat` file is BPI-specific; the
  custom image has no mtkhnat service (upstream PPE offload replaces it).

## 7. Step-by-step checklist

1. Back up config (see §1) on the stock Banana.
2. Flash/boot the custom image (SD first, or sysupgrade).
3. Copy the backup to the new device; extract configs.
4. **Rewrite the LAN/WAN/br-lan section** in `/etc/config/network` (§3).
5. Restore dropbear keys; restart services.
6. `apk update` to refresh feeds; add any missing package.
7. Re-add custom scripts (`/root/*.sh`) and re-apply manual tweaks
   (`ethtool`, fan PWM) — optionally via `/etc/rc.local`.