# chronicblondiee.tech

Source for my technical blog, hosted on GitHub Pages as plain static HTML/CSS
(no build step, no Jekyll).

**Live site:** https://chronicblondiee.github.io/tech-blog/

## Layout

```
index.html    — blog homepage / post index
style.css     — shared stylesheet
posts/        — individual blog posts
poc/          — source for proof-of-concept work referenced in posts
```

## Posts

- [Three Roads to a Read-Only Root](posts/three-roads-to-a-readonly-root.html)
  — the distro decision behind the POC: Ubuntu's overlayroot vs RHEL's
  readonly-root/rwtab vs SUSE's systemd.volatile=overlay, and why the
  choice was really made by the RAM-boot path and the security stack, not
  the volatile-root mechanisms.
- [Booting Is Deployment: MAAS, FOG, and the Problem That Disappeared](posts/booting-is-deployment.html)
  — the deployment systems evaluated for the POC and demoted to the
  disk-deploy fallback once RAM-boot removed the disk itself, plus the two
  roads noted for later: MicroOS's transactional root and KIWI NG image
  builds.
- [The Second Boot Is the Real Test](posts/second-boot-is-the-real-test.html)
  — why "it booted" is the least interesting fact about a boot: the
  verification script behind the POC, the statelessness canary that can't
  pass on the run that plants it, and acceptance as two consecutive clean
  runs across a reboot.
- [Streaming an OS into RAM: The PXE Boot Pipeline](posts/pxe-ram-boot-pipeline.html)
  — the boot path from power button to login prompt: dnsmasq proxyDHCP
  coexisting with corporate DHCP, the single fleet-wide iPXE script, dracut
  livenet copying a squashfs into RAM, and the versioned-image `current`
  symlink that makes deploy and rollback one command.
- [Inside the Keytab Vault: Infisical as a Boot-Time Keystore](posts/inside-the-keytab-vault-infisical.html)
  — deep dive on the keystore behind the POC: the Infisical compose stack,
  the hostname/MAC-aliased secret layout, the staging and boot-time fetch
  flows, and the security model of handing keytabs to stateless hardware.
- [The Keytab Vault: Diskless Bare-Metal Linux with AD Auth via SSSD](posts/stateless-bare-metal-linux-sssd.html)
  — writeup of the POC in [`poc/stateless-sssd-poc`](poc/stateless-sssd-poc),
  a PXE RAM-boot architecture for stateless bare-metal Linux fleets
  authenticating against Active Directory via SSSD, with keytabs pulled from
  an Infisical vault at boot time instead of living on disk.
