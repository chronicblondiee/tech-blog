#!/usr/bin/env bash
# pxe-server-setup.sh — run as root on the DEPLOY SERVER
# (openSUSE Leap / SLES preferred; Ubuntu also supported).
# Installs and configures the entire PXE RAM-boot serving stack:
#   dnsmasq  : proxyDHCP + TFTP (serves tiny iPXE binaries only)
#   nginx    : HTTP for kernel/initrd/squashfs (the heavy lifting)
#   ipxe     : undionly.kpxe (BIOS) + ipxe.efi (UEFI) from the ipxe package
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PXE_SUBNET="${PXE_SUBNET:-10.10.20.0}"          # broadcast domain of the bare-metal nodes
DEPLOY_FQDN="${DEPLOY_FQDN:-deploy.poc.lan}"    # how nodes reach THIS server over HTTP

echo "[1/5] Packages..."
if command -v zypper >/dev/null; then
  zypper --non-interactive refresh
  zypper --non-interactive install dnsmasq nginx ipxe-bootimgs zstd squashfs guestfs-tools 2>/dev/null || \
  zypper --non-interactive install dnsmasq nginx ipxe zstd squashfs libguestfs
elif command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y dnsmasq nginx ipxe zstd squashfs-tools libguestfs-tools
else
  echo "FATAL: need zypper or apt-get on the deploy server"; exit 1
fi

echo "[2/5] Directory layout..."
mkdir -p /srv/tftp /srv/pxe/images
# iPXE binaries: SUSE ships under /usr/share/ipxe, Debian/Ubuntu under /usr/lib/ipxe
IPXE_DIR=""
for d in /usr/share/ipxe /usr/lib/ipxe; do
  [ -f "$d/undionly.kpxe" ] && IPXE_DIR="$d" && break
done
[ -n "$IPXE_DIR" ] || { echo "FATAL: iPXE binaries not found (undionly.kpxe)"; exit 1; }
cp "$IPXE_DIR/undionly.kpxe" /srv/tftp/
cp "$IPXE_DIR/ipxe.efi"      /srv/tftp/ 2>/dev/null || \
cp "$IPXE_DIR"/*.efi         /srv/tftp/ipxe.efi
chmod -R a+r /srv/tftp

echo "[3/5] dnsmasq (proxyDHCP + TFTP)..."
# main dnsmasq must not fight systemd-resolved on port 53: we run DHCP/TFTP only
sed -e "s/@@PXE_SUBNET@@/${PXE_SUBNET}/g" \
    -e "s/@@DEPLOY_FQDN@@/${DEPLOY_FQDN}/g" \
    "${SCRIPT_DIR}/dnsmasq-pxe.conf" > /etc/dnsmasq.d/pxe.conf
# disable DNS function entirely
grep -q '^port=0' /etc/dnsmasq.conf || echo 'port=0' >> /etc/dnsmasq.conf
systemctl enable --now dnsmasq
systemctl restart dnsmasq

echo "[4/5] nginx (HTTP image serving)..."
# SUSE nginx uses conf.d/*.conf (wrap in http via vhosts.d) — use vhosts.d if
# present (SUSE), else sites-available (Debian-style).
if [ -d /etc/nginx/vhosts.d ]; then
  sed -e "s/@@DEPLOY_FQDN@@/${DEPLOY_FQDN}/g" \
      "${SCRIPT_DIR}/nginx-pxe.conf" > /etc/nginx/vhosts.d/pxe.conf
else
  sed -e "s/@@DEPLOY_FQDN@@/${DEPLOY_FQDN}/g" \
      "${SCRIPT_DIR}/nginx-pxe.conf" > /etc/nginx/sites-available/pxe
  ln -sf /etc/nginx/sites-available/pxe /etc/nginx/sites-enabled/pxe
  rm -f /etc/nginx/sites-enabled/default
fi
nginx -t && systemctl enable --now nginx && systemctl reload nginx
# SUSE: open firewall if firewalld is active (TFTP 69/udp, DHCP-proxy 4011/udp, HTTP 80)
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=tftp --add-service=http --add-port=4011/udp --add-port=67/udp
  firewall-cmd --reload
fi

echo "[5/5] Boot script..."
sed -e "s/@@DEPLOY_FQDN@@/${DEPLOY_FQDN}/g" \
    "${SCRIPT_DIR}/boot.ipxe" > /srv/pxe/boot.ipxe
chmod a+r /srv/pxe/boot.ipxe

echo
echo "PXE server ready:"
echo "  TFTP  : /srv/tftp            (undionly.kpxe, ipxe.efi)"
echo "  HTTP  : http://${DEPLOY_FQDN}/boot.ipxe , /images/current/{vmlinuz,initrd.img,root.squashfs}"
echo "Next  : build and publish an image ->  ./build-squashfs.sh golden.qcow2 v1"
echo "Check : from a node subnet host:  curl -I http://${DEPLOY_FQDN}/boot.ipxe"
