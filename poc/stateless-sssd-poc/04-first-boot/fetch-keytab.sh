#!/usr/bin/env bash
# fetch-keytab.sh — runs at every boot via keytab-fetch.service (Before=sssd.service)
#
# 1. Authenticates to Infisical with the read-only 'baremetal-boot' machine identity
# 2. Looks up KEYTAB_<HOSTNAME>; falls back to KEYTAB_MAC_<bootnic MAC>
#    (and, if using the MAC path, also sets the hostname from HOSTNAME_MAC_<MAC>)
# 3. Writes /etc/krb5.keytab (tmpfs on a stateless boot) and validates with kinit -k
#
# Config: /etc/keytab-fetch.env (written by build-golden-image.sh, root 0600)
set -euo pipefail
exec > >(tee -a /run/keytab-fetch.log) 2>&1

ENV_FILE=/etc/keytab-fetch.env
[ -f "$ENV_FILE" ] || { echo "FATAL: $ENV_FILE missing"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${INFISICAL_URL:?}" "${INFISICAL_CLIENT_ID:?}" "${INFISICAL_CLIENT_SECRET:?}"
: "${INFISICAL_PROJECT_ID:?}" "${AD_REALM:?}"
INFISICAL_ENV_SLUG="${INFISICAL_ENV_SLUG:-prod}"
SECRET_PATH="/keytabs"
KEYTAB=/etc/krb5.keytab

log() { echo "[keytab-fetch] $(date -Is) $*"; }

# ---- wait for network + Infisical reachability (max ~90s) -------------------
for i in $(seq 1 30); do
  if curl -sf -m 3 "${INFISICAL_URL}/api/status" >/dev/null 2>&1 || \
     curl -sf -m 3 "${INFISICAL_URL}" >/dev/null 2>&1; then break; fi
  log "waiting for ${INFISICAL_URL} (${i}/30)"; sleep 3
done

# ---- identify self -----------------------------------------------------------
# Varied hardware: NIC count/naming/cabling differs per server, and the
# default-route NIC may not be the one that was inventoried. Collect ALL
# physical NIC MACs (default-route NIC first) and try each against the vault.
BOOT_IF=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
MACS=""
[ -n "${BOOT_IF:-}" ] && [ -f "/sys/class/net/${BOOT_IF}/address" ] && \
  MACS=$(tr 'a-f' 'A-F' < "/sys/class/net/${BOOT_IF}/address" | tr -d ':')
for dev in /sys/class/net/*; do
  ifname=$(basename "$dev")
  [ "$ifname" = "lo" ] && continue
  [ -e "$dev/device" ] || continue            # physical NICs only (skip veth/bond/vlan)
  m=$(tr 'a-f' 'A-F' < "$dev/address" 2>/dev/null | tr -d ':')
  [ -n "$m" ] && [[ " $MACS " != *" $m "* ]] && MACS="$MACS $m"
done
MACS=$(echo "$MACS" | xargs)   # trim
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || echo "")
log "boot_if=${BOOT_IF:-?} macs=[${MACS:-none}] hostname=${HOSTNAME_SHORT:-?}"

# ---- auth to Infisical -------------------------------------------------------
TOKEN=$(curl -sf -X POST "${INFISICAL_URL}/api/v1/auth/universal-auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"clientId\":\"${INFISICAL_CLIENT_ID}\",\"clientSecret\":\"${INFISICAL_CLIENT_SECRET}\"}" \
  | jq -r '.accessToken')
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { log "FATAL: Infisical auth failed"; exit 1; }

get_secret() {  # $1=key ; echoes value or returns 1
  local v
  v=$(curl -sf "${INFISICAL_URL}/api/v3/secrets/raw/$1?workspaceId=${INFISICAL_PROJECT_ID}&environment=${INFISICAL_ENV_SLUG}&secretPath=${SECRET_PATH}" \
        -H "Authorization: Bearer ${TOKEN}" | jq -r '.secret.secretValue // empty') || return 1
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# ---- resolve keytab: hostname first, MAC fallback ---------------------------
B64=""
if [ -n "$HOSTNAME_SHORT" ] && [[ "$HOSTNAME_SHORT" != "localhost" ]]; then
  KEY="KEYTAB_$(echo "$HOSTNAME_SHORT" | tr 'a-z-' 'A-Z_')"
  log "trying ${KEY}"
  B64=$(get_secret "$KEY" || true)
fi
if [ -z "$B64" ] && [ -n "${MACS:-}" ]; then
  for MAC in $MACS; do
    KEY="KEYTAB_MAC_${MAC}"
    log "trying ${KEY}"
    B64=$(get_secret "$KEY" || true)
    [ -z "$B64" ] && continue
    WANT_HN=$(get_secret "HOSTNAME_MAC_${MAC}" || true)
    if [ -n "$WANT_HN" ] && [ "$WANT_HN" != "$HOSTNAME_SHORT" ]; then
      log "setting hostname -> ${WANT_HN} (from vault, keyed by MAC ${MAC})"
      hostnamectl set-hostname "$WANT_HN" || hostname "$WANT_HN"
      HOSTNAME_SHORT="$WANT_HN"
    fi
    break
  done
fi
[ -n "$B64" ] || { log "FATAL: no keytab secret found for host or MAC"; exit 1; }

# ---- install keytab ----------------------------------------------------------
umask 077
printf '%s' "$B64" | base64 -d > "${KEYTAB}.tmp"
[ -s "${KEYTAB}.tmp" ] || { log "FATAL: decoded keytab is empty"; exit 1; }
mv "${KEYTAB}.tmp" "$KEYTAB"
chown root:root "$KEYTAB"; chmod 600 "$KEYTAB"
log "installed ${KEYTAB}:"
klist -kt "$KEYTAB" | sed 's/^/[keytab-fetch]   /'

# ---- clear any stale SSSD cache (should already be empty on tmpfs) ----------
rm -f /var/lib/sss/db/* /var/lib/sss/mc/* 2>/dev/null || true

# ---- validate against the KDC ------------------------------------------------
PRINC="$(echo "$HOSTNAME_SHORT" | tr 'a-z' 'A-Z')\$@${AD_REALM}"
if KRB5CCNAME=MEMORY: kinit -kt "$KEYTAB" "$PRINC" 2>/dev/null; then
  log "OK: kinit as ${PRINC} succeeded — machine identity valid"
else
  log "WARN: kinit as ${PRINC} failed (clock skew? KVNO drift? DNS?) — SSSD will still attempt"
fi

log "done; sssd.service may start"
exit 0
