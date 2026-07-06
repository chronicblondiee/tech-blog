#!/usr/bin/env bash
# build-squashfs.sh <golden.qcow2> <version-label>
#
# Runs on the DEPLOY SERVER (needs libguestfs-tools, squashfs-tools).
# Converts a SEALED golden image into the three PXE RAM-boot artifacts and
# publishes them under a versioned directory with a 'current' symlink:
#
#   /srv/pxe/images/<version>-<date>/{vmlinuz, initrd.img, root.squashfs, SHA256SUMS}
#   /srv/pxe/images/current -> <that dir>       (only when --promote is given)
#
# The golden image must have been built with RAMBOOT=1 (installs dracut
# livenet modules + generic drivers) — this script verifies that.
set -euo pipefail

IMAGE="${1:?Usage: build-squashfs.sh golden.qcow2 v1 [--promote]}"
VERSION="${2:?Usage: build-squashfs.sh golden.qcow2 v1 [--promote]}"
PROMOTE="${3:-}"
OUT_BASE=/srv/pxe/images
STAMP=$(date +%Y-%m-%d)
OUT="${OUT_BASE}/${VERSION}-${STAMP}"
MNT=$(mktemp -d /tmp/goldenmnt.XXXX)

for bin in guestmount guestunmount virt-ls virt-copy-out mksquashfs; do
  command -v "$bin" >/dev/null || { echo "Missing: $bin (apt install libguestfs-tools squashfs-tools)"; exit 1; }
done
mkdir -p "$OUT"

cleanup() { guestunmount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

echo "[1/5] Extracting kernel + initramfs..."
KVER=$(virt-ls -a "$IMAGE" /lib/modules | sort -V | tail -1)
[ -n "$KVER" ] || { echo "FATAL: no kernels found in image"; exit 1; }
echo "      kernel: ${KVER}"
virt-copy-out -a "$IMAGE" "/boot/vmlinuz-${KVER}" "$OUT/"
# initramfs naming: SUSE=/boot/initrd-KVER, Ubuntu=initrd.img-KVER, RHEL=initramfs-KVER.img
virt-copy-out -a "$IMAGE" "/boot/initrd-${KVER}" "$OUT/" 2>/dev/null || \
virt-copy-out -a "$IMAGE" "/boot/initrd.img-${KVER}" "$OUT/" 2>/dev/null || \
virt-copy-out -a "$IMAGE" "/boot/initramfs-${KVER}.img" "$OUT/"
mv "$OUT/vmlinuz-${KVER}" "$OUT/vmlinuz"
mv "$OUT/initrd-${KVER}" "$OUT/initrd.img" 2>/dev/null || \
mv "$OUT"/initrd.img-"${KVER}" "$OUT/initrd.img" 2>/dev/null || \
mv "$OUT"/initramfs-"${KVER}".img "$OUT/initrd.img"

echo "[2/5] Verifying initramfs has livenet + generic drivers (RAMBOOT=1 build)..."
command -v lsinitrd >/dev/null && LS="lsinitrd" || LS="lsinitramfs"
MISSING=""
for want in livenet dmsquash-live overlayfs; do
  $LS "$OUT/initrd.img" 2>/dev/null | grep -qi "$want" || MISSING="$MISSING $want"
done
if [ -n "$MISSING" ]; then
  echo "FATAL: initramfs lacks:${MISSING}"
  echo "       Rebuild the golden image with RAMBOOT=1 ./build-golden-image.sh"
  exit 1
fi
for drv in nvme ahci ixgbe i40e bnxt_en mlx5_core e1000e tg3; do
  $LS "$OUT/initrd.img" 2>/dev/null | grep -q "$drv" || \
    echo "      WARN: NIC/storage driver '$drv' absent — confirm fleet doesn't need it"
done

echo "[3/5] Squashing root filesystem (zstd)..."
guestmount -a "$IMAGE" -i --ro "$MNT"
mksquashfs "$MNT" "$OUT/root.squashfs" \
  -comp zstd -Xcompression-level 15 -noappend -no-xattrs \
  -e boot/vmlinuz* -e boot/initrd* -e boot/initramfs* \
  -e proc -e sys -e dev -e run -e tmp
guestunmount "$MNT"; trap - EXIT; rmdir "$MNT"

echo "[4/5] Checksums..."
( cd "$OUT" && sha256sum vmlinuz initrd.img root.squashfs > SHA256SUMS )
chmod -R a+r "$OUT"

echo "[5/5] Publish..."
ls -lh "$OUT"
SQ_MB=$(du -m "$OUT/root.squashfs" | cut -f1)
echo "      squashfs: ${SQ_MB} MiB  →  node RAM floor ≈ $(( SQ_MB * 2 / 1024 + 4 )) GiB (image×2 + headroom)"
if [ "$PROMOTE" = "--promote" ]; then
  ln -sfn "$OUT" "${OUT_BASE}/current"
  echo "      PROMOTED: images/current -> ${OUT}"
  echo "      Fleet boots this image on next reboot. Rollback: ln -sfn <old-dir> ${OUT_BASE}/current"
else
  echo "      Staged only. Test one node against it (edit its boot.ipxe base or use iPXE shell), then:"
  echo "        ln -sfn ${OUT} ${OUT_BASE}/current"
fi
