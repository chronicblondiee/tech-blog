# Deploying with FOG Project (FALLBACK disk path only)

> Primary deployment is `08-pxe-ramboot/`.

FOG is the alternative when multicast imaging of many identical boxes matters
more than cloud-init-native workflows. FOG has **no native cloud-init
injection**, so specialization uses a NoCloud seed + Snapin instead.

## 1. Install FOG
```bash
git clone https://github.com/FOGProject/fogproject
cd fogproject/bin && sudo ./installfog.sh   # choose Normal server, enable DHCP or point existing DHCP opts 66/67 at FOG
```
Web UI: `http://<fog-host>/fog` (default fog/password — change it).

## 2. Capture the golden image
1. Deploy the sealed golden disk to ONE reference physical machine (dd the raw
   image, or virt-boot it once — do not boot it into the OS beforehand if you
   can avoid it; if you must, re-run the seal steps).
2. FOG UI → **Images → Create New Image**: type `Single Disk - Resizable`,
   OS `Linux`.
3. Register the reference host (PXE menu → "Perform Full Host Registration"),
   associate the image, then task a **Capture**. PXE-boot the host; FOG uploads
   the disk.

## 3. Register targets + deploy
1. PXE-register every target (this records the MAC — verify it matches
   `hosts.csv`; set the FOG host name to the CSV hostname).
2. Task **Deploy** (unicast) or **Multicast** for the whole group.

## 4. Specialization without MAAS (NoCloud seed via Snapin)
Because FOG deploys a bit-perfect clone, per-host identity comes from the
vault's MAC fallback — `fetch-keytab.sh` already:
- looks up `KEYTAB_MAC_<MAC>` when the hostname is generic, and
- sets the hostname from `HOSTNAME_MAC_<MAC>`.

So the minimum viable FOG flow needs **zero snapins**: image boots, MAC lookup
names it and fetches its keytab. 

Optional Snapin (runs post-deploy, pre-first-boot is not possible in FOG; this
runs at first boot via FOG client) to apply the same extras as the cloud-init
file — create `poc-specialize.sh` Snapin:
```bash
#!/usr/bin/env bash
set -e
# SUSE: enable tmpfs overlay over root for next boot
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="systemd.volatile=overlay /' /etc/default/grub
grub2-mkconfig -o /boot/grub2/grub.cfg
systemctl enable keytab-fetch.service
reboot
```
Alternatively, bake the `systemd.volatile=overlay` grub arg straight into the
golden image and skip snapins entirely (recommended).

## Gotchas
- FOG's PXE (iPXE/undionly) and MAAS cannot share the same DHCP scope options — run one deployer per subnet.
- Resizable single-disk capture requires a plain ext4 root; SUSE defaults to btrfs — either build the golden with ext4 root, or pick `Single Disk - Non-Resizable`.
- FOG multicast wants IGMP snooping configured on switches, otherwise it floods.
