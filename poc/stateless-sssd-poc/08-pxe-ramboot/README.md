# PXE RAM-Boot — PRIMARY Deployment Architecture

**This is the primary candidate for the POC.** Every physical server, regardless
of hardware, PXE-boots, pulls a SquashFS of the golden image over HTTP directly
into RAM, and runs entirely from memory with an OverlayFS on top. Local disks
are ignored (or used only as optional scratch/swap).

## Why RAM-boot wins for this fleet

| Property | PXE RAM-boot | Disk deploy + overlayroot |
|---|---|---|
| Statelessness | **Perfect** — power cycle = factory reset, nothing CAN persist | Depends on overlay correctness; lower disk is mutable via escape hatches |
| Varied hardware | **Best** — no disk bootloader, no partition/geometry, no BIOS-vs-UEFI-on-disk, no fstab/UUID concerns; only the kernel/initramfs must know the hardware | Must solve hybrid GRUB, disk naming, resize per model |
| PVS parity | **Closest analogue** — this *is* "stream to RAM, cache in RAM" | Approximation |
| Image rollout | Update one file on the PXE server; **entire fleet on new image at next reboot; rollback = repoint one symlink** | Re-image every node (MAAS/FOG cycle per machine) |
| Keytab exposure | Keytab only ever exists in RAM | Keytab in tmpfs, but disk exists in chassis |
| Costs | Boot-time network pull (~1.5–3 GB/node); RAM budget; PXE infra is a hard dependency at boot | Local boot independence |

The identity flow (**Infisical keytab vault → `keytab-fetch.service` → SSSD**) is
completely unchanged — it was designed to be storage-agnostic. Hostname
assignment already comes from the vault via NIC MAC, which is exactly what a
diskless clone needs.

## Boot mechanism: dracut `livenet` (one mechanism, both distros)

We standardize on **dracut's livenet + dmsquash-live** modules. On the target
OS (SLES 15 / openSUSE Leap) these ship in the standard `dracut` package —
no add-ons, fully SUSE-native. dracut livenet:
- fetches a **bare squashfs** over HTTP (no ISO wrapping step),
- has first-class flags for our exact semantics:
  - `rd.live.ram=1` → copy the image fully to RAM, then release the network hold
  - `rd.live.overlay.overlayfs=1` → tmpfs OverlayFS writable layer
  - `rd.neednet=1 ip=dhcp` → bring up any NIC via DHCP inside initramfs

Kernel cmdline (assembled by `boot.ipxe`):
```
root=live:http://deploy.poc.lan/pxe/images/current/root.squashfs \
rd.live.ram=1 rd.live.overlay.overlayfs=1 rd.live.dir=/ rd.live.squashimg=root.squashfs \
rd.neednet=1 ip=dhcp rd.timeout=120 \
console=tty0 console=ttyS0,115200n8
```

## Component layout (this directory)

| File | Purpose |
|---|---|
| `pxe-server-setup.sh` | Installs dnsmasq (proxyDHCP+TFTP) + nginx (HTTP image serving) + iPXE binaries on the deploy server |
| `dnsmasq-pxe.conf` | ProxyDHCP config: BIOS clients → `undionly.kpxe`, UEFI → `ipxe.efi`, iPXE clients → chain `boot.ipxe` over HTTP |
| `boot.ipxe` | The single fleet boot script (versioned image path, cmdline above) |
| `nginx-pxe.conf` | HTTP server for squashfs/kernel/initrd with sendfile + range support |
| `build-squashfs.sh` | Golden qcow2 → `{vmlinuz, initrd.img, root.squashfs}` in a **versioned** directory + `current` symlink |

## End-to-end flow

```
power on ─▶ NIC PXE ROM ─▶ dnsmasq proxyDHCP (arch detect)
   BIOS ──▶ undionly.kpxe ─┐
   UEFI ──▶ ipxe.efi ──────┤ (TFTP, tiny)
                           ▼
                     iPXE loads http://deploy/boot.ipxe
                           ▼
        HTTP: vmlinuz + initrd.img  (fast, resumable)
                           ▼
   dracut initramfs: DHCP ─▶ HTTP GET root.squashfs ─▶ copy to RAM
                           ▼
   OverlayFS(tmpfs) over squashfs root ─▶ systemd
                           ▼
   keytab-fetch.service: MAC ─▶ Infisical ─▶ hostname + /etc/krb5.keytab
                           ▼
   sssd.service ─▶ AD auth live.  Reboot ⇒ everything above repeats, pristine.
```

## ProxyDHCP: coexisting with corporate DHCP

`dnsmasq-pxe.conf` runs in **proxyDHCP** mode: your existing DHCP server keeps
handing out IPs untouched; dnsmasq only supplements the PXE boot options. No
changes to corporate DHCP scopes, no option 66/67 fights. (If the POC subnet
has no DHCP at all, flip the commented `dhcp-range` line to authoritative
mode.)

## Image versioning & instant rollback (operational superpower)

```
/srv/pxe/images/
├── v1-2026-07-06/   {vmlinuz, initrd.img, root.squashfs, SHA256SUMS}
├── v2-2026-07-20/   {...}
└── current -> v2-2026-07-20
```
`boot.ipxe` always references `images/current/…`. Promote = `ln -sfn`,
rollback = `ln -sfn` back, effective fleet-wide at next reboot. Nodes never
partially upgrade — every boot is atomic by construction.

## Scaling & sizing

- **RAM per node:** squashfs (zstd) of a lean server image ≈ 1.5–2.5 GB;
  budget `squashfs × 1.2 (RAM copy) + unpacked working set + workload`.
  Practical floor: **8 GB**, comfortable: 16 GB+.
- **Boot storm:** N nodes × squashfs over unicast HTTP. nginx + 10 GbE handles
  dozens of simultaneous boots; for larger fleets stagger power-on via
  IPMI/iDRAC, or place a per-rack nginx cache (`proxy_cache`) — both are
  config-only. (Multicast is a FOG/disk-imaging trick; livenet is unicast.)
- **PXE server availability:** it's only needed AT BOOT. Running nodes are
  unaffected by PXE server downtime. For the POC one server is fine; note for
  prod: two dnsmasq/nginx instances behind the same content are trivially
  active-active (PXE clients retry).
- **Optional local scratch:** varied local disks can still be used as
  ephemeral scratch/swap without harming statelessness — e.g. a boot-time unit
  that mkfs's the first disk to `/scratch`. Never mount anything from disk
  into `/etc` or `/var/lib/sss`.

## Runbook

1. On the deploy server: `sudo ./pxe-server-setup.sh` (installs dnsmasq, nginx,
   fetches iPXE binaries, lays out `/srv/tftp` + `/srv/pxe`, installs the two
   config files + `boot.ipxe`).
2. Build the SUSE golden image (`01-golden-image/`, with
   `RAMBOOT=1 ./build-golden-image.sh` — enables dracut livenet modules and
   regenerates a generic, non-hostonly initramfs). Seal it.
   (SUSE-native alternative for later: build the live artifacts declaratively
   with **KIWI NG** — see `05-stateless-boot/suse-stateless-notes.md`.)
3. `sudo ./build-squashfs.sh golden.qcow2 v1` → publishes
   `/srv/pxe/images/v1-<date>/` and points `current` at it.
4. Set target servers to PXE-first boot order (the only per-node touch, done
   once at racking) and power on.
5. Run `07-verification/verify-poc.sh`, reboot, run again.

## Failure-mode notes

| Symptom | Cause | Fix |
|---|---|---|
| PXE ROM gets IP but no boot file | proxyDHCP not seen (different L2/VLAN) | dnsmasq must sit on the same broadcast domain or use `dhcp-relay`; check `tcpdump port 4011` |
| iPXE loads, kernel loads, hangs in initramfs at network | initramfs missing NIC driver/firmware | `RAMBOOT=1` build step embeds full driver set — verify with `lsinitrd \| grep <driver>`; add firmware to image |
| `Failed to fetch squashfs` | nginx unreachable from initramfs / wrong URL | `rd.timeout` gives 120 s; test `curl -I` of the squashfs URL from another host; check VLAN/MTU |
| Boots but root read-only errors under load | tmpfs overlay full (small-RAM node) | journald already volatile+capped; raise RAM or trim image; check `df -h /run/overlayfs` |
| UEFI box loops back to PXE menu | Secure Boot enabled | Disable Secure Boot for the POC, or switch iPXE binary to signed shim+GRUB chain (documented prod path) |
