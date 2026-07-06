# Stateless Bare-Metal Linux + SSSD POC — Full Implementation Guide

**Architecture:** Approach 2 — "The Keytab Vault" (API-Driven Injection)
**Target OS:** SLES 15 SP5+ / openSUSE Leap 15.5+ (Leap for POC, SLES for prod — binary compatible; see `05-stateless-boot/suse-stateless-notes.md`)
**Boot model (PRIMARY):** PXE RAM-boot — SquashFS streamed over HTTP into RAM every boot, fully diskless. Disk-deploy + OverlayFS is the fallback only.
**Target:** Physical bare-metal servers, stateless/ephemeral OS, AD auth strictly via SSSD.
**Secrets Manager:** Infisical (self-hosted, Docker). No HashiCorp Vault, no Winbind, no Citrix PVS.

---

## 0. How This Package Is Organized

| Dir | Purpose | Runs On |
|---|---|---|
| `01-golden-image/` | Build + seal the master image (SSSD pre-configured, NOT joined) | Build VM / hypervisor |
| `02-infisical/` | Deploy Infisical secrets manager | Docker host on POC network |
| `03-keytab-staging/` | Pre-create AD computer objects, generate keytabs, upload to Infisical | Admin/staging Linux host with AD reachability |
| `04-first-boot/` | cloud-init + systemd unit that pulls the keytab on boot before SSSD starts | Baked into golden image / injected by MAAS |
| `08-pxe-ramboot/` | **PRIMARY: full PXE RAM-boot stack** — dnsmasq proxyDHCP, iPXE, nginx, squashfs pipeline | Deploy server |
| `05-stateless-boot/` | FALLBACK: disk-deploy OverlayFS/readonly-root + hardware portability rules | Golden image |
| `06-deployment/` | OPTIONAL (fallback path only): MAAS and FOG disk-imaging runbooks | Deployment server |
| `07-verification/` | End-to-end validation script | Target physical server |

**Execution order (primary): 02 → 03 → 01 (with `RAMBOOT=1`) → 08 → 07.**
(Infisical must exist before keytabs can be staged; keytabs must be staged before a node can boot successfully. Phases 05/06 are only used if you fall back to disk deployment.)

---

## 1. Prerequisites & Assumptions

Replace these placeholder values everywhere (grep for them across the repo):

| Placeholder | Meaning | Example |
|---|---|---|
| `EXAMPLE.CORP` | Kerberos realm (UPPERCASE) | `AD.CONTOSO.COM` |
| `example.corp` | AD DNS domain (lowercase) | `ad.contoso.com` |
| `dc01.example.corp` | Domain controller FQDN | — |
| `infisical.poc.lan` | Infisical server FQDN/IP | `10.10.20.5` |
| `OU=StatelessLinux,DC=example,DC=corp` | Target OU for computer objects | — |

Requirements:

1. A service/admin AD account with rights to create computer objects in the target OU (delegated "Create Computer Objects" + "Reset Password" is sufficient; Domain Admin not required).
2. DNS: physical servers must resolve DCs and `infisical.poc.lan`. Time sync (chrony/NTP against DCs) — Kerberos tolerates ±5 min skew only.
3. A Linux staging host with: `adcli`, `krb5-client` (SUSE) / equivalent, `curl`, `jq`, `base64`. Any distro works — it only talks LDAP/Kerberos + HTTPS.
4. A Docker host (2 vCPU / 4 GB RAM minimum) for Infisical.
5. MAAS or FOG server on the same L2/PXE network as the bare-metal targets (see `06-deployment/`).
6. Inventory of target servers: hostname + boot-NIC MAC address (fill in `03-keytab-staging/hosts.csv`).

---

## 2. Phase-by-Phase Runbook

### Phase 1 — Deploy Infisical (`02-infisical/`)

1. Copy `.env.example` → `.env`, generate the two required secrets:
   ```bash
   openssl rand -hex 16   # ENCRYPTION_KEY
   openssl rand -base64 32 # AUTH_SECRET
   ```
2. `docker compose up -d`, browse to `http://infisical.poc.lan:8080`, create the admin account.
3. Follow `02-infisical/setup-infisical.md` to:
   - Create project **`stateless-keytabs`** (note the **Project ID**).
   - Create a **Machine Identity** named `baremetal-boot` with **Universal Auth**, attach it to the project with **read-only** permission on the `/keytabs` secret path.
   - Record `CLIENT_ID` and `CLIENT_SECRET` — these go into the golden image boot config (POC-acceptable; see §4 Security Notes).
   - Create a second Machine Identity `keytab-stager` with **read/write** on `/keytabs` for the staging script.

### Phase 2 — Pre-Stage AD Objects + Keytabs (`03-keytab-staging/`)

1. Fill `hosts.csv` with one line per physical server: `hostname,mac_address`.
2. Export the stager credentials and AD join credentials, then run:
   ```bash
   export INFISICAL_URL=http://infisical.poc.lan:8080
   export INFISICAL_CLIENT_ID=<keytab-stager client id>
   export INFISICAL_CLIENT_SECRET=<keytab-stager client secret>
   export INFISICAL_PROJECT_ID=<project id>
   export AD_JOIN_USER=svc-linuxjoin
   ./stage-keytabs.sh hosts.csv
   ```
3. What the script does per host:
   - `adcli join --computer-name=<HOST>` from the staging box — this **creates the computer object once** in the target OU and writes `<HOST>.keytab` locally. The object is created exactly one time; reboots never re-join, so **no duplicate AD objects ever appear**.
   - Base64-encodes the keytab and uploads it to Infisical at secret path `/keytabs`, key `KEYTAB_<HOSTNAME>` (uppercase, dashes→underscores). A second key `KEYTAB_MAC_<MAC>` (colons stripped) is written pointing at the same value so the boot script can look up by MAC if hostname isn't assigned yet.
4. Verify in the Infisical UI that one secret pair exists per host.

### Phase 3 — Build & Seal the Golden Image (`01-golden-image/`)

1. Create an openSUSE Leap 15.5+ (POC) or registered SLES 15 SP5+ VM on any hypervisor. SLES: run `SUSEConnect -r <regcode>` before the build script so zypper repos resolve; `SUSEConnect -d` before sealing.
2. Copy this repo into the VM and run `RAMBOOT=1 ./build-golden-image.sh` as root (RAMBOOT=1 builds the dracut livenet initramfs required for PXE RAM-boot — the primary path). It:
   - Installs `sssd sssd-ad sssd-krb5 sssd-tools adcli krb5-client chrony curl jq kernel-firmware ucode-* NetworkManager` via zypper, wires PAM/NSS with `pam-config` + `compat sss`, and swaps wicked for NetworkManager (match-all DHCP for varied NICs, `hostname-mode=none` so the vault-assigned hostname wins).
   - Renders `/etc/sssd/sssd.conf` and `/etc/krb5.conf` from `templates/` (domain pre-configured, **no join performed**).
   - Sets `ad_maximum_machine_account_password_age = 0` — **critical**: disables SSSD's machine-password rotation. A stateless host must never rotate the password, or the vaulted keytab becomes stale after 30 days.
   - Installs `04-first-boot/fetch-keytab.sh` → `/usr/local/sbin/` and `keytab-fetch.service` → systemd, ordered `Before=sssd.service`.
   - Writes `/etc/keytab-fetch.env` with the Infisical URL + `baremetal-boot` read-only credentials.
   - RAMBOOT=1 builds the dracut livenet initramfs (SUSE dracut ships the modules natively). Disk-deploy fallback statelessness uses `systemd.volatile=overlay` instead of Ubuntu's overlayroot.
3. Shut the VM down and run `seal-image.sh` **from the hypervisor host** against the disk image (`virt-sysprep`: strips machine-id, SSH host keys, logs, DHCP leases, MAC caches).
4. Capture/export the sealed disk (raw/qcow2 → convert per deployer requirements, see `06-deployment/`).

### Phase 4 — PXE RAM-Boot Infrastructure (`08-pxe-ramboot/`) — PRIMARY

1. On the deploy server: `sudo ./pxe-server-setup.sh` (env: `PXE_SUBNET`, `DEPLOY_FQDN`). Installs dnsmasq in **proxyDHCP** mode (coexists with corporate DHCP — no scope changes), TFTP serving only the tiny iPXE binaries (BIOS `undionly.kpxe` / UEFI `ipxe.efi` selected by DHCP arch option 93), and nginx serving the heavy artifacts over HTTP.
2. Publish the image: `sudo ./build-squashfs.sh golden.qcow2 v1 --promote`. This extracts kernel+initramfs, **verifies the initramfs contains livenet/dmsquash-live/overlayfs and the common NIC/RAID drivers** (fails fast if the image wasn't built with `RAMBOOT=1`), squashes the root (zstd), writes SHA256SUMS, and points `images/current` at it.
3. Set every target server to PXE-first boot order (one-time, at racking). Power on. There is **no per-node deployment step** — booting IS deployment.
4. Fleet image lifecycle: publish `v2` without `--promote`, test one node, then `ln -sfn` the `current` symlink. Rollback is the same symlink flip. Every boot is atomic — nodes can never be partially upgraded.

Full architecture rationale, boot-flow diagram, RAM sizing, boot-storm scaling, and failure-mode table: `08-pxe-ramboot/README.md`.

### Phase 5 — FALLBACK ONLY: Disk Deployment (`05-stateless-boot/` + `06-deployment/`)

Use only for nodes that can't RAM-boot (insufficient RAM, no PXE-capable NIC, or a network segment where PXE is prohibited): deploy the sealed SUSE image to disk via MAAS (`maas-deploy.md`) or FOG (`fog-deploy.md`) and enable statelessness with the kernel arg **`systemd.volatile=overlay`** (SUSE has no overlayroot package — mechanics in `suse-stateless-notes.md`), observing the hybrid BIOS/UEFI bootloader rules in `hardware-portability.md`. The identity flow is identical either way.

### Phase 6 — Boot-Time Flow (what happens automatically)

```
Power on → PXE ROM → dnsmasq proxyDHCP (arch detect) → iPXE (TFTP, tiny)
  → iPXE chains http://deploy/boot.ipxe → kernel+initrd over HTTP
  → dracut livenet: HTTP GET root.squashfs → copied fully into RAM
  → tmpfs OverlayFS mounted over the squashfs root → systemd
  → network up (DHCP) → chrony syncs to DC
  → keytab-fetch.service:
       1. Reads hostname; falls back to boot-NIC MAC
       2. POST /api/v1/auth/universal-auth/login  → short-lived access token
       3. GET  /api/v3/secrets/raw/KEYTAB_<HOST>  (or KEYTAB_MAC_<MAC>)
       4. base64 -d → /etc/krb5.keytab  (root:root 0600, lives in tmpfs only)
       5. Sanity check: kinit -kt /etc/krb5.keytab '<HOST>$@REALM'
  → sssd.service starts → AD users can authenticate
Reboot → ENTIRE OS discarded from RAM → keytab gone → re-streams pristine image.
AD object untouched. Local disks never consulted. PXE server only needed at boot.
```

### Phase 7 — Verify (`07-verification/`)

On a deployed server run `verify-poc.sh`. It checks: overlay active, time sync, keytab present with correct principal, `kinit -k` succeeds, SSSD healthy, `id <ad-user>` resolves, and confirms exactly one computer object exists (via `adcli show-computer`). Then **reboot and run it again** — the pass criteria for the POC is a clean second pass with zero manual steps and zero new AD objects.

---

## 2b. Heterogeneous Hardware — Design Rules (read before building the image)

The fleet has **varied physical hardware**. One golden image serves all of it only if these invariants hold (details + rationale in `05-stateless-boot/hardware-portability.md`; the build script automates most of them):

1. **Generic initramfs** — SUSE dracut defaults to hostonly; the build forces `hostonly="no"` + full `kernel-firmware`/`ucode-*`. Automated in `build-golden-image.sh` steps 6–8, with a driver-presence check for common RAID/NIC modules.
2. **UUID/LABEL boot only** — the build script *fails* if `/etc/fstab` has `/dev/sdX`-style entries; virt-sysprep intentionally preserves FS UUIDs.
3. **Mixed BIOS/UEFI** — GPT + `bios_grub` partition + ESP, both loaders installed (`--removable` for the EFI fallback path). Or standardize firmware. **The primary architecture (PXE RAM-boot, `08-pxe-ramboot/`) avoids disk bootloaders entirely — this item applies only to the disk-deploy fallback.**
4. **No NIC-specific network config** — wicked is disabled in favor of NetworkManager (auto-DHCP on any wired NIC, zero per-interface files); `hostname-mode=none` protects the vault-assigned hostname.
5. **Multi-NIC identity resolution** — `fetch-keytab.sh` tries *every physical NIC MAC* against the vault; `hosts.csv` accepts semicolon-separated MAC lists per host, and `stage-keytabs.sh` writes an alias per MAC. Any cabled port resolves the right keytab and hostname.
6. **Disk-size variance** — irrelevant on the primary RAM-boot path; for the disk fallback: growpart on boot #1, FOG `Single Disk - Resizable`, avoid btrfs/LVM root for FOG resizing.
7. **Dual console** — `console=tty0 console=ttyS0,115200n8` so iDRAC/iLO serial-over-LAN always shows output.
8. **RAM variance** — journald volatile + capped at 64M so small-RAM boxes don't fill the tmpfs overlay.
9. **Per-model smoke test** — deploy to one unit of *each* hardware model and run `verify-poc.sh` + `dmesg -l err` before fleet rollout; fix gaps by adding drivers to the single image, never by forking per-model images.

---

## 3. Troubleshooting Quick Table

| Symptom | Likely Cause | Fix |
|---|---|---|
| `kinit: Preauthentication failed` using keytab | KVNO mismatch — something rotated the machine password after staging | Re-run `stage-keytabs.sh` for that host; confirm `ad_maximum_machine_account_password_age = 0` in sssd.conf |
| `kinit: Clock skew too great` | No NTP against DCs | Ensure chrony sources = DCs; verify `chronyc tracking` |
| fetch script: HTTP 401 from Infisical | Wrong client id/secret, or identity not attached to project | Re-check machine identity project access + role |
| fetch script: HTTP 404 secret | Hostname mismatch vs. staged key | Confirm key naming (uppercase, `-`→`_`), or MAC fallback key exists |
| SSSD starts but `id user` fails | DNS SRV lookups failing | `dig SRV _ldap._tcp.example.corp`; fix resolv.conf/DHCP option 6 |
| Writes appear on disk after reboot | Overlay not active | `mount | grep overlayroot`; check kernel cmdline |
| Duplicate computer objects in AD | Something ran `realm join` on the host | Ensure golden image never joins; only `stage-keytabs.sh` touches AD |
| Kernel panic "unable to mount root fs" on some models | Host-only initramfs missing storage driver | Rebuild image with `MODULES=most` / `hostonly=no`; check `lsinitramfs` for megaraid_sas/mpt3sas/nvme |
| Boots on model A, no bootloader found on model B | BIOS vs UEFI mismatch (disk fallback only) | Hybrid GPT + both loaders (guide §2b.3) — or stay on the primary RAM-boot path, which has no disk bootloader |
| No network on some models | NIC firmware missing or stale wicked ifcfg files | Confirm `kernel-firmware` installed; ensure wicked is disabled and no ifcfg-* files ship in the image |
| `zypper install` fails in golden VM (SLES) | Not registered | `SUSEConnect -r <regcode>` (or point at RMT/SUSE Manager); `SUSEConnect -d` before sealing |
| Keytab fetch fails only on multi-NIC boxes | Cabled port's MAC not staged | Add all NIC MACs semicolon-separated in hosts.csv and re-run stage-keytabs.sh (aliases only; AD object untouched if it exists — see note below) |

---

**Note on re-running `stage-keytabs.sh` for an existing host:** `adcli join` against an existing computer object does not create a duplicate — it resets that object's password and emits a fresh keytab (new KVNO), which the script immediately uploads. So re-staging is always safe and self-consistent; the affected node just needs one reboot to pick up the new keytab.

---

## 4. Security Notes (POC vs. Production)

- **POC shortcut:** the `baremetal-boot` Universal Auth client secret is baked into the image (`/etc/keytab-fetch.env`, root 0600, read-only scope). Acceptable for a lab.
- **Production hardening path:** switch the machine identity to Infisical **conditional access / IP allowlists**, per-host identities, or attest via TPM/hardware serial; serve Infisical over TLS with a real cert (set `INFISICAL_URL=https://...`); rotate the stager credentials after staging; restrict the `/keytabs` path per-host if per-host identities are used.
- Keytab only ever exists in tmpfs on the target — power-off destroys it.
- AD hygiene: one object per physical host, created once, never rotated. Disable/remove via `adcli delete-computer` when decommissioning.

---

## 5. Success Criteria Checklist

- [ ] Infisical up, two machine identities scoped correctly
- [ ] One AD computer object + one Infisical secret pair per host in `hosts.csv`
- [ ] Golden image sealed; contains fetch unit but **no keytab and no join state**
- [ ] PXE server serves boot.ipxe + current image; node RAM-boots with zero interactive steps
- [ ] `verify-poc.sh` confirms `root=live:` + `rd.live.ram=1` (no network dependency after boot)
- [ ] First boot: `verify-poc.sh` passes
- [ ] Reboot: OS pristine, keytab re-fetched, `verify-poc.sh` passes again
- [ ] AD object count for host = 1 (unchanged across ≥3 reboots)
