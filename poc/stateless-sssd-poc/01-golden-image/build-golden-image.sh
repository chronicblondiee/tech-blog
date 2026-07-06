#!/usr/bin/env bash
# build-golden-image.sh
# TARGET OS: SLES 15 SP5+/SP6 or openSUSE Leap 15.5+ (zypper-based).
# Run as root INSIDE the golden image VM.
#
# Installs the SSSD/AD stack pre-configured (NO domain join), the boot-time
# keytab fetch unit, NetworkManager match-all DHCP, and (RAMBOOT=1, the
# PRIMARY path) a dracut livenet initramfs for PXE RAM-boot.
#
# SLES note: register first or attach to RMT/SUSE Manager so repos resolve:
#   SUSEConnect -r <regcode>            # base
#   (adcli/sssd live in the base + Basesystem modules on SLES 15)
set -euo pipefail

# ------------------------------------------------------------------ settings
AD_DOMAIN="${AD_DOMAIN:-example.corp}"            # lowercase DNS domain
AD_REALM="${AD_REALM:-EXAMPLE.CORP}"              # UPPERCASE realm
DC_FQDN="${DC_FQDN:-dc01.example.corp}"           # a reachable DC (chrony + fallback)
INFISICAL_URL="${INFISICAL_URL:-http://infisical.poc.lan:8080}"
INFISICAL_CLIENT_ID="${INFISICAL_CLIENT_ID:-REPLACE_ME}"          # baremetal-boot (READ-ONLY identity)
INFISICAL_CLIENT_SECRET="${INFISICAL_CLIENT_SECRET:-REPLACE_ME}"
INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID:-REPLACE_ME}"
INFISICAL_ENV_SLUG="${INFISICAL_ENV_SLUG:-prod}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

command -v zypper >/dev/null || {
  echo "FATAL: zypper not found — target OS is SLES/openSUSE. (Older Ubuntu/RHEL"
  echo "build logic was removed when the fleet standardized on SUSE.)"; exit 1; }

echo "[1/9] Installing packages (zypper)..."
zypper --non-interactive refresh
zypper --non-interactive install \
  sssd sssd-ad sssd-krb5 sssd-tools adcli krb5-client \
  chrony curl jq \
  kernel-default kernel-firmware ucode-intel ucode-amd \
  NetworkManager dracut \
  cloud-init growpart 2>/dev/null || \
zypper --non-interactive install \
  sssd sssd-ad sssd-krb5 sssd-tools adcli krb5-client \
  chrony curl jq kernel-default kernel-firmware NetworkManager dracut
# (second attempt tolerates missing optional pkgs e.g. ucode/growpart naming per SP)

echo "[2/9] Rendering /etc/krb5.conf and /etc/sssd/sssd.conf..."
render() { sed -e "s/@@AD_DOMAIN@@/${AD_DOMAIN}/g" \
               -e "s/@@AD_REALM@@/${AD_REALM}/g" \
               -e "s/@@DC_FQDN@@/${DC_FQDN}/g" "$1"; }
render "${SCRIPT_DIR}/templates/krb5.conf.tpl"  > /etc/krb5.conf
render "${SCRIPT_DIR}/templates/sssd.conf.tpl"  > /etc/sssd/sssd.conf
chmod 600 /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf

echo "[3/9] PAM (pam-config) + NSS (nsswitch compat sss)..."
pam-config -a --sss
pam-config -a --mkhomedir --mkhomedir-umask=0077
# SUSE ships 'compat' NSS sources; append sss
sed -i -E 's/^(passwd:\s+).*/\1compat sss/; s/^(group:\s+).*/\1compat sss/' /etc/nsswitch.conf
grep -qE '^shadow:.*sss' /etc/nsswitch.conf || sed -i -E 's/^(shadow:\s+).*/\1compat sss/' /etc/nsswitch.conf

echo "[4/9] Chrony -> domain controllers (Kerberos needs tight clocks)..."
CHRONY_CONF=/etc/chrony.conf
if ! grep -q "${DC_FQDN}" "$CHRONY_CONF"; then
  printf '\n# POC: sync against AD DC\nserver %s iburst prefer\n' "${DC_FQDN}" >> "$CHRONY_CONF"
fi
systemctl enable chronyd

echo "[5/9] Installing keytab-fetch boot unit..."
install -m 0755 "${REPO_ROOT}/04-first-boot/fetch-keytab.sh" /usr/local/sbin/fetch-keytab.sh
install -m 0644 "${REPO_ROOT}/04-first-boot/keytab-fetch.service" /etc/systemd/system/keytab-fetch.service
cat > /etc/keytab-fetch.env <<EOF
INFISICAL_URL=${INFISICAL_URL}
INFISICAL_CLIENT_ID=${INFISICAL_CLIENT_ID}
INFISICAL_CLIENT_SECRET=${INFISICAL_CLIENT_SECRET}
INFISICAL_PROJECT_ID=${INFISICAL_PROJECT_ID}
INFISICAL_ENV_SLUG=${INFISICAL_ENV_SLUG}
AD_REALM=${AD_REALM}
EOF
chmod 600 /etc/keytab-fetch.env
systemctl daemon-reload
systemctl enable keytab-fetch.service
systemctl enable sssd

echo "[6/9] HARDWARE PORTABILITY: generic dracut initramfs (varied bare metal)..."
# SUSE dracut defaults to hostonly — a VM-built initramfs would lack the RAID/
# NVMe/NIC drivers real servers need. Force generic; RAMBOOT=1 (PRIMARY) also
# adds livenet + dmsquash-live + overlayfs for PXE RAM-boot
# (root=live:http://.../root.squashfs rd.live.ram=1).
mkdir -p /etc/dracut.conf.d
if [ "${RAMBOOT:-0}" = "1" ]; then
  echo "      RAMBOOT=1 → dracut livenet initramfs (PXE RAM-boot primary path)"
  cat > /etc/dracut.conf.d/90-ramboot.conf <<'EOF'
hostonly="no"
add_dracutmodules+=" livenet dmsquash-live overlayfs network base "
add_drivers+=" overlay squashfs loop "
install_items+=" /usr/bin/curl "
compress="zstd"
EOF
else
  cat > /etc/dracut.conf.d/99-no-hostonly.conf <<'EOF'
hostonly="no"
compress="zstd"
EOF
fi
KVER=$(ls -1 /lib/modules | sort -V | tail -1)
dracut -f "/boot/initrd-${KVER}" "$KVER"
echo "      built /boot/initrd-${KVER}"
# presence check for common bare-metal storage/NIC drivers
for drv in megaraid_sas mpt3sas smartpqi ahci nvme ixgbe i40e bnxt_en mlx5_core tg3 e1000e; do
  lsinitrd "/boot/initrd-${KVER}" 2>/dev/null | grep -q "$drv" || \
    echo "  WARN: driver '$drv' not in initramfs — verify fleet doesn't need it"
done
if [ "${RAMBOOT:-0}" = "1" ]; then
  for mod in livenet dmsquash-live overlayfs; do
    lsinitrd "/boot/initrd-${KVER}" 2>/dev/null | grep -qi "$mod" || {
      echo "FATAL: dracut module '$mod' missing from initramfs"; exit 1; }
  done
fi

echo "[7/9] HARDWARE PORTABILITY: UUID-only fstab audit + dual console..."
# (Fallback disk-deploy only; irrelevant when RAM-booting, but keep the image honest.)
if grep -E '^\s*/dev/(sd|vd|nvme|hd)' /etc/fstab; then
  echo "FATAL: /etc/fstab contains device-name entries above — convert to UUID=/LABEL= and re-run."
  exit 1
fi
if [ -f /etc/default/grub ] && ! grep -q 'console=ttyS0' /etc/default/grub; then
  sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8 /' /etc/default/grub
  grub2-mkconfig -o /boot/grub2/grub.cfg || true
fi
ROOTDEV=$(findmnt -n -o SOURCE /) && command -v e2label >/dev/null && e2label "$ROOTDEV" ROOTFS 2>/dev/null || true

echo "[8/9] HARDWARE PORTABILITY: NetworkManager match-all DHCP + volatile journald..."
# wicked (SUSE default) needs per-interface ifcfg files — wrong model for a
# fleet with varied NIC names/counts. NetworkManager auto-activates DHCP on
# ANY wired NIC with zero per-interface config.
systemctl disable wicked wickedd 2>/dev/null || true
systemctl enable NetworkManager
rm -f /etc/sysconfig/network/ifcfg-eth* /etc/sysconfig/network/ifcfg-en* 2>/dev/null || true
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/90-poc.conf <<'EOF'
[main]
# vault-assigned hostname (HOSTNAME_MAC_<MAC>) must win over DHCP option 12
hostname-mode=none

[connection]
# auto-DHCP any wired NIC; no per-interface profiles shipped in the image
connection.autoconnect=true
EOF
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/poc-volatile.conf <<'EOF'
[Journal]
Storage=volatile
SystemMaxUse=64M
RuntimeMaxUse=64M
EOF

echo "[9/9] Sanity: ensure we are NOT joined (no keytab, no cached identity)..."
rm -f /etc/krb5.keytab
rm -rf /var/lib/sss/db/* /var/lib/sss/mc/* 2>/dev/null || true

echo "DONE. Next steps:"
if [ "${RAMBOOT:-0}" = "1" ]; then
  echo "  PRIMARY (PXE RAM-boot): power off, run seal-image.sh, then on the deploy server:"
  echo "    08-pxe-ramboot/build-squashfs.sh golden.qcow2 v1 --promote"
else
  echo "  DISK-DEPLOY FALLBACK on SUSE: statelessness via kernel arg systemd.volatile=overlay"
  echo "  (see 05-stateless-boot/suse-stateless-notes.md), then seal-image.sh."
fi
echo "  Smoke-test on ONE unit of EACH hardware model before fleet rollout."
