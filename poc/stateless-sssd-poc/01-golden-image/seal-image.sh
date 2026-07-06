#!/usr/bin/env bash
# seal-image.sh
# Run on the HYPERVISOR HOST (not inside the VM) after the golden VM is powered off.
# Strips all unique identity so every deployed clone is pristine.
# Requires: libguestfs-tools (apt) / guestfs-tools (dnf)
set -euo pipefail

IMAGE="${1:?Usage: seal-image.sh /path/to/golden.qcow2}"

command -v virt-sysprep >/dev/null || {
  echo "Install libguestfs: apt-get install -y libguestfs-tools  (or dnf install guestfs-tools)"; exit 1; }

echo ">>> Sealing ${IMAGE}"
# NOTE: default operations already remove machine-id, ssh host keys, logs,
# dhcp leases, udev-persistent-net, tmp files. We keep 'customize' off.
virt-sysprep -a "${IMAGE}" \
  --operations defaults,-fs-uuids \
  --delete /etc/krb5.keytab \
  --delete '/var/lib/sss/db/*' \
  --delete '/var/lib/sss/mc/*' \
  --delete '/var/log/sssd/*'

# Explicitly verify no keytab / machine-id survived
virt-cat -a "${IMAGE}" /etc/machine-id 2>/dev/null | grep -q . && {
  echo "WARN: /etc/machine-id still populated"; } || echo "OK: machine-id empty"

echo ">>> Sealed. Convert per deployer:"
echo "    MAAS: qemu-img convert -O raw ${IMAGE} golden.img && gzip golden.img"
echo "    FOG : deploy qcow2/raw to a reference physical box once, then capture with FOG."
