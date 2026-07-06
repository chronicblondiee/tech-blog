> **LEGACY REFERENCE — fleet target OS is now SLES/openSUSE.** For SUSE use
> `suse-stateless-notes.md` (`systemd.volatile=overlay` fallback) and
> `08-pxe-ramboot/` for the primary path. Kept for mixed-estate reference only.

# Stateless Boot — Ubuntu

## Method A: OverlayFS via `overlayroot` (recommended for the POC)

`overlayroot` (from the `cloud-initramfs-tools` family, installed by
`build-golden-image.sh`) mounts a tmpfs overlay on top of the read-only root
inside the initramfs — exactly the PVS "Cache in RAM" semantic.

### Enable
Two equivalent switches (the cloud-init user-data sets both):

1. Config file baked/dropped into the image:
   ```
   # /etc/overlayroot.conf
   overlayroot="tmpfs:swap=1,recurse=0"
   ```
2. Or kernel cmdline (works even on a fully read-only image):
   ```
   overlayroot=tmpfs:swap=1,recurse=0
   ```
   Add to `GRUB_CMDLINE_LINUX` in `/etc/default/grub`, then `update-grub`.

### Deployment lifecycle nuance (important)
- **First boot after imaging must be read-write** so cloud-init can specialize
  (hostname, grub arg, users). The user-data enables overlayroot *for the next
  boot*. From boot #2 onward the node is stateless.
- If you want boot #1 stateless too, pre-set `/etc/overlayroot.conf` in the
  golden image and move all specialization into the vault (hostname via
  `HOSTNAME_MAC_<MAC>` — already supported by `fetch-keytab.sh`).

### Verify
```bash
mount | grep -E 'overlayroot|overlay / '
# expect: overlayroot on / type overlay ... lowerdir=/media/root-ro,upperdir=/media/root-rw...
touch /root/canary && reboot
# after reboot: /root/canary must NOT exist
```

### Maintenance escape hatch
To intentionally persist a change (e.g., patching the deployed disk):
```bash
overlayroot-chroot        # chroots into the real read-write lower disk
# make changes, exit, reboot
```
…but for this architecture, prefer re-imaging from a new golden version.

---

## Method B: PXE RAM-Boot — NOW THE PRIMARY ARCHITECTURE

**Superseded by `08-pxe-ramboot/` (dracut livenet, full server stack, versioned
images). Use that. The casper notes below are kept only as an Ubuntu-native
alternative reference.**

### Legacy casper reference

1. **Squash the sealed golden image** (on the build host):
   ```bash
   guestmount -a golden.qcow2 -i --ro /mnt/golden
   mksquashfs /mnt/golden /srv/tftp/images/golden.squashfs -comp zstd -noappend
   guestunmount /mnt/golden
   ```
2. **Extract kernel/initrd** from the image into the TFTP root:
   ```bash
   virt-copy-out -a golden.qcow2 /boot/vmlinuz /boot/initrd.img /srv/tftp/images/
   ```
   The initramfs must contain casper (Ubuntu live) or `overlayroot`+network
   modules. Easiest: `apt install casper` inside the golden VM before sealing.
3. **iPXE / pxelinux entry** (HTTP fetch into RAM, `toram` keeps it there):
   ```
   kernel http://deploy.poc.lan/images/vmlinuz
   initrd http://deploy.poc.lan/images/initrd.img
   imgargs vmlinuz boot=casper netboot=http url=http://deploy.poc.lan/images/golden.squashfs toram ip=dhcp ---
   boot
   ```
4. Local disks are ignored entirely; `/etc/krb5.keytab` lives in RAM and the
   same `keytab-fetch.service` flow applies unchanged.

**Sizing:** the SquashFS + working set must fit in RAM. A minimal server image
squashes to ~1.5–2.5 GB; budget image-size × 2 + workload RAM.

**Trade-off vs Method A:** truly diskless and zero local state, but every boot
pulls the full image over the network (use multicast or 10 GbE for fleets) and
kernel updates mean re-squashing.
