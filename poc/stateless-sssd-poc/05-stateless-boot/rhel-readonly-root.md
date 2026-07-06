> **LEGACY REFERENCE — fleet target OS is now SLES/openSUSE.** For SUSE use
> `suse-stateless-notes.md` (`systemd.volatile=overlay` fallback) and
> `08-pxe-ramboot/` for the primary path. Kept for mixed-estate reference only.

# Stateless Boot — RHEL 9 / Rocky / Alma

RHEL has no `overlayroot` package; two supported patterns:

## Option 1: readonly-root (initscripts-service)
Built into `initscripts` (`readonly-root` service).

```bash
dnf install -y initscripts-service
```

`/etc/sysconfig/readonly-root`:
```
READONLY=yes
TEMPORARY_STATE=yes
```

- Root is mounted `ro`; writable paths are enumerated in
  `/etc/rwtab` and `/etc/rwtab.d/*` and backed by tmpfs.
- Add an entry so the keytab and SSSD state are writable (tmpfs → wiped on reboot):

`/etc/rwtab.d/sssd-poc`:
```
files	/etc/krb5.keytab
dirs	/var/lib/sss
dirs	/var/log/sssd
```

Note: `files /etc/krb5.keytab` copies an (empty/absent) placeholder into tmpfs;
`fetch-keytab.service` then writes the real keytab into that tmpfs copy each boot.

## Option 2: overlay via dracut kernel arg
Recent dracut supports a live overlay on a read-only root:
```
rd.live.overlay.overlayfs=1 rd.live.overlay.readonly=1
```
Most robust when combined with a squashfs live image (Method B):
```
kernel ... root=live:http://deploy.poc.lan/images/golden.squashfs rd.live.image rd.live.ram=1 rd.live.overlay.overlayfs=1
```
(`rd.live.ram=1` = copy image to RAM = diskless, PVS-like.)

## Verify (either option)
```bash
mount | grep -E ' / .*\bro\b|overlay'
touch /root/canary && reboot   # canary must be gone after reboot
```

## SSSD specifics on RHEL
- `authselect select sssd with-mkhomedir --force` (done by build script).
- SELinux: keytab written by the fetch script gets `etc_t` via default
  transition; if SSSD is denied, run once during image build:
  ```bash
  semanage fcontext -a -t krb5_keytab_t /etc/krb5.keytab
  restorecon -v /etc/krb5.keytab
  ```
  and keep `restorecon /etc/krb5.keytab` as the last step of the fetch script
  (harmless on Ubuntu; add if you target RHEL).
