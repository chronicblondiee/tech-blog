# Deploying with Canonical MAAS (FALLBACK disk path only)

> Primary deployment is `08-pxe-ramboot/`. Use MAAS only for nodes that cannot
> RAM-boot. MAAS deploys the **SUSE** golden image fine via `ddgz` — the disk
> is written verbatim, so the OS inside is irrelevant to MAAS.

MAAS is the smoothest path for this POC because it natively injects
cloud-init user-data, knows every machine's MAC, and names machines —
which lines up 1:1 with the keytab staging model.

## 1. Install MAAS (single-host POC)
```bash
sudo snap install maas
sudo snap install maas-test-db
sudo maas init region+rack --database-uri maas-test-db:///
sudo maas createadmin
```
Web UI: `http://<maas-host>:5240/MAAS`
- Configure the PXE subnet: enable **DHCP** on the fabric/VLAN facing the bare-metal nodes (or configure external-DHCP relay).
- Set upstream DNS so deployed nodes can resolve `example.corp` and `infisical.poc.lan` (Settings → Network → DNS forwarders → your AD DCs).

## 2. Enlist + commission the hardware
1. Set each server's BIOS to PXE-boot first.
2. Power on → MAAS auto-enlists → machine appears as `New`.
3. **Rename each machine to match `hosts.csv`** (e.g., `bm-node01`). This is what makes `KEYTAB_<HOSTNAME>` resolve on boot. Cross-check the boot NIC MAC against the CSV.
4. Commission (default scripts fine) → state `Ready`.
5. Configure power drivers (IPMI/Redfish) if available so MAAS can cycle nodes.

## 3. Upload the golden image as a custom image
```bash
qemu-img convert -O raw golden.qcow2 golden-sssd.img
gzip golden-sssd.img
maas $PROFILE boot-resources create \
  name='custom/suse-sssd-stateless' \
  title='SUSE SSSD Stateless Golden' \
  architecture='amd64/generic' \
  filetype='ddgz' \
  content@=golden-sssd.img.gz
```
(`ddgz`/`ddraw` deploys the disk verbatim regardless of the OS inside — exactly what we want since the SUSE image is fully pre-configured.)

## 4. Deploy with the POC user-data
UI: select machine → **Deploy** → OS = your custom image → paste
`04-first-boot/cloud-init-user-data.yaml` into **Cloud-init user-data**.

CLI:
```bash
maas $PROFILE machine deploy <system_id> \
  osystem=custom distro_series=suse-sssd-stateless \
  user_data="$(base64 -w0 04-first-boot/cloud-init-user-data.yaml)"
```

## 5. Boot sequence expectations
- Deploy boot: MAAS writes disk, cloud-init specializes (hostname, grub systemd.volatile=overlay arg, users), reboots.
- Boot #2 onward: volatile overlay active → keytab-fetch → sssd → stateless steady state.

## 6. Re-imaging / golden image updates
Release the machine in MAAS and redeploy with the new image version. The AD
object and the vaulted keytab are untouched — the node reclaims its identity
on first boot automatically. **This is the core payoff of the architecture.**

## Gotchas
- MAAS `Ready` machines are powered off with an ephemeral OS — nothing to do there.
- If nodes have multiple NICs, ensure the CSV MAC = PXE NIC MAC (MAAS UI → machine → Network shows which one PXE'd).
- MAAS DNS: if MAAS runs DNS for the subnet, add a forwarder to the AD DCs or SSSD's SRV discovery will fail.
