# Stateless Bare-Metal SUSE + SSSD POC (Keytab Vault + PXE RAM-Boot)

**Target OS: SLES 15 / openSUSE Leap** (Leap for the POC, SLES for prod — binary-compatible).

Replaces Citrix PVS's Winbind-bound streaming model with a natively-Linux
equivalent: **every boot, physical servers PXE-stream a SquashFS golden image
over HTTP directly into RAM** (diskless, tmpfs OverlayFS on top), then pull
their AD machine keytab from **Infisical** so **SSSD** authenticates — with
**zero duplicate computer objects, ever**, and zero reliance on local disks.
This is the true "Cache in RAM" analogue, and the most portable option for a
fleet with **varied hardware** (no disk bootloaders, partitions, or
BIOS/UEFI-on-disk concerns).

```
                 ┌─────────────┐   pre-stage once    ┌──────────────┐
                 │  Admin box  │ ── adcli join ────▶ │ Active Dir.  │
                 │ (03-staging)│ ◀─ HOST.keytab ──── │ (1 obj/host) │
                 └──────┬──────┘                     └──────▲───────┘
                        │ base64 + upload                   │ kinit -k / SSSD
                        ▼                                   │
                 ┌─────────────┐  fetch @ every boot  ┌─────┴──────────────┐
                 │  Infisical  │ ◀── universal auth ──│  Bare-metal node   │
                 │ /keytabs/*  │ ─── keytab (b64) ──▶ │  ── RAM only ──    │
                 └─────────────┘                      │ squashfs + overlay │
                                                      └─────▲──────────────┘
                 ┌──────────────────────┐   PXE + HTTP      │ every boot
                 │ Deploy server (08-)  │───────────────────┘
                 │ dnsmasq·iPXE·nginx   │  vmlinuz / initrd / root.squashfs
                 │ images/current ─▶ vN │  (promote/rollback = one symlink)
                 └──────────────────────┘
```

**Start here → `IMPLEMENTATION_GUIDE.md`**, then `08-pxe-ramboot/README.md`
for the primary boot architecture deep-dive.

## Layout
```
01-golden-image/    build-golden-image.sh (use RAMBOOT=1), seal-image.sh, templates
02-infisical/       docker-compose.yml, .env.example, setup runbook
03-keytab-staging/  stage-keytabs.sh, hosts.csv.example (multi-MAC per host)
04-first-boot/      fetch-keytab.sh (tries ALL NIC MACs), keytab-fetch.service
05-stateless-boot/  FALLBACK disk-deploy (systemd.volatile=overlay) + hardware
                    portability + suse-stateless-notes.md (SUSE platform guide)
06-deployment/      FALLBACK MAAS / FOG disk-imaging runbooks
07-verification/    verify-poc.sh (validates live RAM root, reboot canary)
08-pxe-ramboot/     ★ PRIMARY: pxe-server-setup.sh, dnsmasq-pxe.conf,
                      boot.ipxe, nginx-pxe.conf, build-squashfs.sh
```

## Execution order (primary path)
`02 (Infisical) → 03 (stage keytabs) → 01 (RAMBOOT=1 build + seal) → 08 (PXE server + publish squashfs) → power on → 07 (verify, reboot, verify)`

## Global placeholders to replace (grep the repo)
`EXAMPLE.CORP` · `example.corp` · `dc01.example.corp` · `infisical.poc.lan` ·
`deploy.poc.lan` · `OU=StatelessLinux,DC=example,DC=corp` · `PXE_SUBNET` ·
Infisical `REPLACE_ME` credentials.

## Non-negotiable design invariants
1. Golden image **never** joins the domain. Only `stage-keytabs.sh` touches AD.
2. `ad_maximum_machine_account_password_age = 0` — machine password never rotates.
3. `keytab-fetch.service` is ordered `Before=sssd.service`.
4. RAM-boot uses `rd.live.ram=1` — after boot the node has **no** dependency on the PXE server, and nothing (OS or keytab) ever touches local disk.
5. Fleet image changes go through the versioned `images/current` symlink — atomic per boot, instant rollback.
