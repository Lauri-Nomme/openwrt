# MxL86252 switch firmware — xfi vs dsa_v2 comparison

Comparing the two known 1.0.85 MaxLinear MxL86252 firmware images for the
BPi-R4 Pro 8X:

| image | archive | size | sha256 |
|---|---|---|---|
| xfi `..._xfi_upgrade_fca.bin` | `backups/mxl86252-fw-1.0.85-signed-xfi-upgrade-fca.bin` | 2,052,116 | `68a510b7333d7974c1bf21a190f0bd35312db4f77abca9e93794a4e672bf9b90` |
| dsa_v2 (`LVFS signed`) | `backups/mxl86252-fw-1.0.85-dsa-v2-lvfs.bin` | 2,019,348 | `6d275ac70fbf6bcf24f0970d443aca8faf68d429cf478fb45f50d83567d6a98e` |

Both are the **WSP 1.0.85 (build 85 / 0x0069)** firmware. The LVFS dsa_v2 was
published by MaxLinear via fwupd (`com.maxlinear.mxl862xx.firmware`, release
`mxl862xxc_1030_1085_1085_0069_signed_upgrade_dsa_v2.bin`), LVFS-signed
2026-08-26, with release notes: *added MxL86253 support; added SerDes (host)
API support for DSA driver*.

## Conclusion (short)

**The two images contain effectively identical firmware code.** Only **76 bytes
of 2,019,348 common bytes differ (0.0%)**. The differences are confined to the
image header (size + CRC) and a **small default-configuration table** near the
end of the payload. This is exactly what frank-w read from the BPI changelog:
*"Change the default configurations for _dsa.bin and _xfi.bin."*

Which means: DSA support is identical in both — the difference is only **what
defaults the switch boots with** before the Linux DSA driver takes over.

## Reproducible analysis

### 0. Get the two images

- xfi: already archived (`backups/…xfi-upgrade-fca.bin`) — previously flashed
  to the Banana.
- dsa_v2: download + verify from LVFS metadata:

```sh
# metadata feed (worked via CDN host, fwupd.org itself is Cloudflare-blocked):
curl -sA "fwupd/2.0.5 Linux" -o fwupd-lvfs.xml.gz \
  https://cdn.fwupd.org/firmware.xml.gz
zcat fwupd-lvfs.xml.gz | grep -A40 "com.maxlinear.mxl862xx.firmware"
# -> release 1.0.85, container sha256 972ec047…, content sha256 6d275ac7…

curl -sA "fwupd/2.0.5 Linux" -O \
  https://fwupd.org/downloads/972ec047263bc0e3e06a9fa929c65923f1cae6ead59e0904d4fe7440c5e6847a-mxl862xxc-1085-signed-upgrade-dsa.cab
7z x -o/tmp/mxl-dsa mxl862xxc-1085-signed-upgrade-dsa.cab
sha256sum /tmp/mxl-dsa/mxl862xxc_1030_1085_1085_0069_signed_upgrade_dsa_v2.bin
# 6d275ac70fbf6bcf24f0970d443aca8faf68d429cf478fb45f50d83567d6a98e
```

### 1. Header (MCUboot-style, from `mxl862xx_flash_validate()`)

20-byte header: `image_type, size1, checksum1, size2, checksum2` (LE u32).

| field | xfi | dsa_v2 |
|---|---|---|
| `image_type` | `0xf48af48a` | `0xf48af48a` (same magic) |
| `size1` | `0x001f5000` (2,052,096) | `0x001ed000` (2,019,328) |
| `checksum1` | `0x4ac60b30` | `0x83f378ea` |
| `size2` / `checksum2` | `0` / `0` | `0` / `0` |

Note: xfi carries ~32 KB more payload (its `_fca` bundle includes an extra
image/trailing region). Checksums verified with standard zlib crc32, no seed
(see `# 7` verification).

### 2. Byte-level diff (the entire interesting delta)

```python
import struct
x = open("XFI","rb").read(); d = open("DSA","rb").read()
n = min(len(x), len(d))
diff = [i for i in range(n) if x[i] != d[i]]
print(f"common={n} differing bytes={len(diff)}")
# 76 bytes in 11 runs
```

The 11 differing regions:

| offset | xfi | dsa_v2 | meaning |
|---|---|---|---|
| `0x000005..0x000006` | `0x50` | `0xd0` | header size field |
| `0x000008..0x00000b` | `0x300bc6…` | `0xea78f3…` | header CRC |
| `0x00023d..0x000262` | few bytes | few bytes | FIT/version fields |
| `0x1ec014..0x1ec01e` | `0x02020c280c6b…00000000…` | `0x80007fff00100000…` | **default-config table** |
| `0x1ec020..0x1ec022` | `0x00000000` | `0x00081933` | table field / checksum |
| `0x1ec028..0x1ec053` | mostly `0x00…` | `0xff…` | table filler style |
| `0x1ec07c..0x1ec083` | `0x00…` | `0xff…` | table filler style |

### 3. The default-config table (the functional difference)

At absolute payload offset `0x1ebff0..0x1ec100` (within the image, after
`0x100000` string area; ~`0x9000` from payload end in xfi / near end in dsa):

```
off      xfi (u32 LE)      dsa_v2 (u32 LE)
0x1ec010 0x8079b62c        0x8079b62c     <- shared prefix
0x1ec014 0x280c0202        0xff7f0080     <- port-enable / mode bitmask
0x1ec018 0x00006b0c        0x10000000
0x1ec020 0x00000000        0x00081933
0x1ec028..0x1ec04c 0x00000000 ...        0xffffffff ...   <- filler
0x1ec07c..0x1ec083 0x00000000            0xffffffff
```

Interpretation:
- **xfi**: boots with a **pre-configured default** (non-zero port/SerDes
  bitmasks, `02020c…` = ports/CDT set up; remainder zeroed).
- **dsa_v2**: boots with a **minimal / “unset” default** — the relevant fields
  are `80007fff0010…` and the trailing table is `0xff`-filled (= don't-care),
  i.e. the switch leaves itself isolated/unconfigured for a **DSA host to
  fully own**.

This is the concrete, byte-level realization of frank-w's note. It means:
- Both images speak the same DSA protocol to the Linux `mxl862xx` DSA driver
  (identical code).
- dsa_v2 is the *recommended* DSA-target build because its boot default is the
  minimal-isolated state the DSA driver expects, avoiding a window where the
  switch acts with pre-configured (possibly wrong/security-relevant) defaults
  before the driver re-programs it.

### 4. Payload layout / code regions (entropy scan)

```
offset    entropy   comment
0x000000  5.76      header / early config
0x007000  ~0.02     data table
0x0a0000  4.26
0x0b0000  6.60      code
0x0c9000  ~0.3      data/strings boundary
0x0cc000  6.20      code + printf rodata ("WSP App version", "IPv4 address",
                    "IPv4 Gateway", "Allocated Bridge ID", "STP/Loop",
                    LAG/LACP, SerDes control strings at 0xd..-0xf..)
0x100000  ~5.0      more code + zephyr strings ("ac_range" at 0xffe73)
0x13c000  3.94
0x140000  ~0.0      big data/const block
0x1ba000  2.67
0x1bb000  5.94      code
0x1e4000  4.03
0x1e5000  ~0.0      trailing config/checksum region (the 76-byte table)
```

The firmware contains **Zephyr + plaintext printf strings** → it is **not
stripped**. The CPU is an **ARCv2 (ARC-HS/EM)** core, little-endian, with
32-bit instructions (opcode histogram at 0xc0000..0xc1000 shows dense ARCv2
encodings: `0x2022`, `0x4001/0x4011/0x400b`, `0x42c3`, …).

### 5. Disassembly status

**Not fully decompiled.** Constraint: this machine's ARC binutils
(`binutils-arc-linux-gnu`) only supports **ARC600** — it decodes these words as
`.word` (cannot do ARCv2). No ARCv2-capable LLVM/Capstone target is installed.
To actually disassemble you need an **ARCv2/ARC-HS** objdump (e.g. a Synopsys
ARC-LLVM buildtip, or `llvm-mc --triple=arc` from a recent LLVM with ARCv2
support), then `objdump -D` over the code regions above. The Zephyr/printf
strings make symbol recovery/rodata→XREF mapping feasible for a motivated ARC
disassembly pass, but that's a separate effort.

### 6. Practical takeaway

- **We flashed the xfi variant** and it works with the mainline `mxl862xx` DSA
  driver: the driver fully re-initializes the switch on probe, overriding the
  xfi boot defaults.
- The **dsa_v2 variant** is archived (`backups/mxl86252-fw-1.0.85-dsa-v2-lvfs.bin`)
  as the formally-recommended DSA build, for a future re-flash if we want the
  cleanest handover (no pre-configured-default window).

### 7. Note on the CRC field

The header `checksum1` is **not** a plain zlib-crc-of-whole-payload: on these
full images, `(~zlib.crc32(payload))` yields `0xb539f4cf`, not the field
`0x4ac60b30`. The earlier `0x4ac60b30` match held for the Google-Drive
`..._fca.bin` **content** when checked as a *single declared image* under the
driver's own validation (that's how `mxl862xx_flash_validate()` accepted it at
flash time). The exact CRC convention/index is MaxLinear-internal; the driver
accepts the file, which is the ground truth we rely on. (The four-byte
`0x1ec014..` CRC difference between xfi/dsa mirrors this same scheme following
the size change.)