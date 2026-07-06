# Hardware Portability — One Golden Image, Varied Physical Servers

The fleet has **heterogeneous hardware** (different NICs, storage controllers,
disk types/sizes, BIOS vs UEFI, vendors). A golden image built inside a VM will
silently assume VM hardware unless the following are enforced. Every item here
is either automated in `build-golden-image.sh` or called out as a deploy-time
rule.

---

## 1. Kernel & initramfs must be generic (CRITICAL)

The #1 failure mode: initramfs built on the build VM only contains virtio
drivers → physical box panics with "unable to mount root fs" (or livenet hangs
with no NIC).

**SLES / openSUSE** use dracut, which defaults to **hostonly** — this WILL
break on different hardware. The build script forces generic:
```
# /etc/dracut.conf.d/99-no-hostonly.conf  (or 90-ramboot.conf when RAMBOOT=1)
hostonly="no"
```
then rebuilds `/boot/initrd-<kver>` with `dracut -f`.

**Firmware/microcode** so NICs/HBAs/RAID controllers initialize on any vendor:
`kernel-firmware ucode-intel ucode-amd` (installed by the build script).

Common bare-metal drivers to sanity-check are present
(`lsinitrd /boot/initrd-<kver> | grep`): `megaraid_sas`, `mpt3sas`, `smartpqi`
(HP), `ahci`, `nvme`, `bnx2x`/`bnxt_en` (Broadcom), `ixgbe`/`i40e`/`ice`
(Intel), `mlx5_core` (Mellanox), `tg3`, `e1000e`, `r8169`. The build script
warns on absences; `build-squashfs.sh` re-checks at publish time.

## 2. Never reference device names — UUIDs/labels only

`/dev/sda` on one box is `/dev/nvme0n1` on another and `/dev/sdb` behind a
RAID controller on a third.

- `/etc/fstab`: every entry must be `UUID=` or `LABEL=` (build script audits
  this and fails the build if a `/dev/sdX` or `/dev/vdX` entry exists).
- GRUB: `root=UUID=...` (grub-mkconfig does this by default; the audit
  verifies).
- This is also why `seal-image.sh` runs virt-sysprep with `-fs-uuids`
  **excluded from the wipe list** — filesystem UUIDs are intentionally
  preserved so every clone's fstab/grub still resolves. UUID collision across
  clones is a non-issue for standalone servers (it only matters if two clones'
  disks are attached to the same host).
- OverlayFS Method A: label the root filesystem (`e2label / ROOTFS` at build)
  so recovery/scripts can find the lower disk generically.

---

## 3. BIOS vs UEFI in a mixed fleet

Pick ONE of these strategies:

**Strategy A (recommended): let MAAS handle it.** MAAS detects firmware per
machine during commissioning and boots accordingly; for `ddgz` custom images,
partition the golden disk as **GPT with BOTH**:
- a 1 MiB `bios_grub` partition (BIOS boot), and
- a 512 MiB ESP (`/boot/efi`, FAT32),
and install both loaders in the golden VM:
```bash
grub-install --target=i386-pc /dev/vda
grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable
```
(`--removable` installs to `EFI/BOOT/BOOTX64.EFI` — the fallback path — so it
boots on any vendor's UEFI without NVRAM entries, which don't survive
cloning anyway.)

**Strategy B: standardize firmware.** Flip every server to UEFI in BIOS setup
during racking. Operationally simplest if you control the hardware intake.

**Method B (PXE RAM-boot) sidesteps this entirely** — the PXE server serves
BIOS (undionly/pxelinux) or UEFI (ipxe.efi/grubnetx64) binaries per DHCP
arch option 93, and no disk bootloader exists at all. **On highly varied
hardware, Method B is the most portable architecture** — strongly consider it
as the primary rather than the fallback (RAM sizing permitting).

---

## 4. NIC variance (naming, count, speed)

- **Never** ship interface-specific network config. Predictable names differ
  per machine (`eno1`, `enp3s0f0`, `ens192`...). SUSE's default **wicked**
  wants a per-interface `ifcfg-<name>` file — wrong model here. The build
  script disables wicked and enables **NetworkManager**, which auto-activates
  DHCP on ANY wired NIC with zero per-interface files, and sets
  `hostname-mode=none` so DHCP never overwrites the vault-assigned hostname.
- **Multi-NIC identity:** `fetch-keytab.sh` tries **every physical NIC's
  MAC** against the vault (not just the default-route NIC), so it doesn't
  matter which port was cabled/PXE'd. Stage **all plausible MACs** per host —
  `hosts.csv` accepts semicolon-separated MACs: `bm-node01,AA:..:01;AA:..:02`.

## 5. Disk size variance

- MAAS `ddgz` writes the image verbatim; on a larger disk the root partition
  doesn't auto-grow. The golden image includes `cloud-init`'s
  `growpart`/`resizefs` (Ubuntu default) — leave `growpart: mode: auto` so
  boot #1 expands root to the physical disk. (Under OverlayFS from boot #2 the
  lower disk size is largely irrelevant anyway — all writes go to RAM.)
- FOG: use `Single Disk - Resizable` image type; FOG shrinks/grows ext4 per
  target disk automatically. LVM golden images force Non-Resizable — prefer
  plain ext4 root for this fleet.
- Smallest disk in the fleet defines the max golden image footprint. Keep the
  image lean (< smallest disk − ESP − scratch).

---

## 6. Console & out-of-band access

Headless vendor variance (iDRAC/iLO/XCC serial-over-LAN) — add both consoles
to the kernel cmdline so you always get output somewhere:
```
console=tty0 console=ttyS0,115200n8
```
(Build script appends this to `GRUB_CMDLINE_LINUX_DEFAULT`; harmless on boxes
without serial.)

---

## 7. RAM variance (Method A sizing)

tmpfs overlay defaults to 50% of RAM. Boxes with small RAM + chatty logs can
fill the overlay → root goes read-only mid-run. Mitigations already in the
image: `journald` capped (`SystemMaxUse=64M`, `Storage=volatile`), and
`overlayroot=tmpfs:swap=1` allows swap backing where a local disk exists.
For Method B, minimum RAM = squashfs size × ~2 + workload.

---

## 8. Per-hardware smoke test (add to POC scope)

Deploy the image to **one unit of each distinct hardware model** before fleet
rollout and run `07-verification/verify-poc.sh` plus:
```bash
dmesg -l err,crit,alert,emerg | grep -vi 'ACPI'   # driver/firmware errors
ip -br link                                        # all expected NICs up
lsblk -o NAME,SIZE,MODEL                           # storage seen correctly
```
Record a hardware-compatibility matrix (model → pass/fail → missing driver).
Any model needing an out-of-tree driver (rare NICs, exotic RAID) gets its
driver added to the ONE golden image — never fork per-model images.
