# SLES / openSUSE Platform Notes (Target OS)

The fleet standardizes on **SLES 15 SP5+/SP6** or **openSUSE Leap 15.5+**.
Everything in this repo is SUSE-first; this file collects the SUSE-specific
decisions and the disk-deploy fallback mechanics.

## Why SUSE is a strong fit for the primary architecture

- SUSE uses **dracut natively** — the exact livenet/dmsquash-live modules the
  PXE RAM-boot path relies on ship in the standard `dracut` package. No add-on
  packages, no casper, no distro-specific initramfs tooling.
- AppArmor (not SELinux) — no keytab relabeling concerns; the default sssd
  profile permits `/etc/krb5.keytab`.
- `pam-config` gives idempotent PAM wiring (`--sss --mkhomedir`).

## SLES vs openSUSE for the POC

| | SLES 15 | openSUSE Leap 15.x |
|---|---|---|
| Repos | Requires `SUSEConnect -r <regcode>` (or RMT/SUSE Manager) in the golden VM before `zypper install` | No registration |
| Binary compatibility | — | Leap 15.x is binary-compatible with SLES 15 (shared codebase) — POC on Leap, prod on SLES is a legitimate path |
| Support | Vendor-supported (matters for prod AD/SSSD escalations) | Community |

Recommendation: **develop the POC on Leap** (zero licensing friction), keep
the build script identical, flip to registered SLES for the production golden
image.

## Networking: NetworkManager, not wicked

SLES defaults to **wicked**, which wants a per-interface `ifcfg-<name>` file —
unusable across varied hardware where NIC names/counts differ per model.
The build script disables wicked and enables **NetworkManager**, which
auto-activates DHCP on any wired NIC with no per-interface config, and sets
`hostname-mode=none` so the vault-assigned hostname (via `HOSTNAME_MAC_<MAC>`)
is never overwritten by DHCP option 12.

## Disk-deploy FALLBACK statelessness: `systemd.volatile=overlay`

SUSE has no `overlayroot` package (Ubuntu-ism). The clean SUSE mechanism is
systemd's native volatile mode — one kernel argument:

```
systemd.volatile=overlay
```

- systemd mounts a tmpfs **OverlayFS upper layer over the root filesystem**
  inside the initramfs; the disk lower layer is used read-only.
- Add to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then
  `grub2-mkconfig -o /boot/grub2/grub.cfg`.
- Requires the `overlayfs` dracut bits — already guaranteed because the build
  script forces a generic initramfs with the overlay driver.
- Verify: `mount | grep 'overlay on / '` and the reboot canary in
  `07-verification/verify-poc.sh`.

(Alternative SUSE-native model: openSUSE MicroOS / SLE Micro's transactional
read-only btrfs root. Powerful, but a different OS variant and snapshot
model — out of scope for this POC, noted for the roadmap.)

## KIWI (SUSE's native image builder) — optional pipeline upgrade

This repo builds the PXE artifacts from a sealed qcow2 via
`08-pxe-ramboot/build-squashfs.sh` (guestmount + mksquashfs) — deliberately
distro-agnostic and simple.

SUSE's first-party alternative is **KIWI NG** (`python3-kiwi`), which builds
**live/PXE image types from a declarative XML/YAML description** and produces
kernel + initrd + squashfs natively (its live images boot via the
`kiwi-live` dracut module, same `rd.live.*` semantics). If the POC graduates,
migrating the image build to KIWI buys: reproducible described-not-crafted
images, OBS (Open Build Service) integration, and no golden-VM-plus-seal step.
The PXE server side (`dnsmasq`/`iPXE`/`nginx`, versioned `images/current`)
stays identical either way.

## Package name map (what the build script installs)

| Function | SUSE package |
|---|---|
| SSSD + AD provider | `sssd sssd-ad sssd-krb5 sssd-tools` |
| AD object/keytab tooling | `adcli` |
| Kerberos client | `krb5-client` |
| Time sync | `chrony` (service: `chronyd`) |
| Firmware/microcode (varied HW) | `kernel-firmware ucode-intel ucode-amd` |
| initramfs | `dracut` (livenet/dmsquash-live/overlayfs included) |
| Networking | `NetworkManager` |
| PAM/NSS wiring | `pam-config` (in `pam`), manual `compat sss` in nsswitch |

## Gotchas observed on SUSE specifically

- **initrd naming:** SUSE is `/boot/initrd-<kver>` (no `.img`) —
  `build-squashfs.sh` handles all three conventions (Ubuntu/RHEL/SUSE).
- **`zypper` in the golden VM on SLES fails** with "no repositories" →
  register first (`SUSEConnect -r ...`); deregister (`SUSEConnect -d`) before
  sealing if the image must not carry credentials — re-registration is not
  needed at runtime for RAM-booted nodes (no package installs happen on a
  stateless node by design).
- **Firewalld** is enabled by default on some SLES patterns — the POC image
  only needs outbound (Infisical, DCs), so default zones are fine; if you
  harden, keep outbound 88/389/636/464/53/123 + Infisical port open.
- `sssctl` lives in `sssd-tools` (installed) — used by `verify-poc.sh`.
