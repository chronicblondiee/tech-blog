#!/usr/bin/env bash
# stage-keytabs.sh <hosts.csv>
#
# Runs on an ADMIN/STAGING Linux host with network reach to AD + Infisical.
# For each host in the CSV:
#   1. Creates the AD computer object ONCE via `adcli join` (run remotely with
#      --computer-name; the local staging box's identity is untouched because
#      we point --host-keytab at a per-host file and never install it).
#   2. Base64-encodes the resulting keytab.
#   3. Uploads it to Infisical under /keytabs as:
#        KEYTAB_<HOSTNAME>            (uppercase, '-' -> '_')
#        KEYTAB_MAC_<MAC>             (colons stripped, uppercase) — boot fallback
#
# Required env:
#   INFISICAL_URL, INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET (keytab-stager identity)
#   INFISICAL_PROJECT_ID
#   AD_JOIN_USER                      (account delegated to create computers in the OU)
# Optional env:
#   AD_DOMAIN (default example.corp), AD_OU (default OU=StatelessLinux,...)
#   INFISICAL_ENV_SLUG (default prod), KEYTAB_DIR (default ./keytabs)
#
# The script prompts once for AD_JOIN_USER's password (used for every host).
set -euo pipefail

CSV="${1:?Usage: stage-keytabs.sh hosts.csv}"
AD_DOMAIN="${AD_DOMAIN:-example.corp}"
AD_OU="${AD_OU:-OU=StatelessLinux,DC=example,DC=corp}"
INFISICAL_ENV_SLUG="${INFISICAL_ENV_SLUG:-prod}"
KEYTAB_DIR="${KEYTAB_DIR:-./keytabs}"
SECRET_PATH="/keytabs"

: "${INFISICAL_URL:?}" "${INFISICAL_CLIENT_ID:?}" "${INFISICAL_CLIENT_SECRET:?}"
: "${INFISICAL_PROJECT_ID:?}" "${AD_JOIN_USER:?}"

for bin in adcli curl jq base64 klist; do
  command -v "$bin" >/dev/null || { echo "Missing dependency: $bin"; exit 1; }
done

mkdir -p "$KEYTAB_DIR"; chmod 700 "$KEYTAB_DIR"

read -rs -p "AD password for ${AD_JOIN_USER}: " AD_JOIN_PASS; echo

echo ">>> Authenticating to Infisical..."
ACCESS_TOKEN=$(curl -sf -X POST "${INFISICAL_URL}/api/v1/auth/universal-auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"clientId\":\"${INFISICAL_CLIENT_ID}\",\"clientSecret\":\"${INFISICAL_CLIENT_SECRET}\"}" \
  | jq -r '.accessToken')
[ -n "$ACCESS_TOKEN" ] && [ "$ACCESS_TOKEN" != "null" ] || { echo "Infisical auth failed"; exit 1; }

upsert_secret() {  # $1=key $2=value
  local key="$1" val="$2" body http
  body=$(jq -n --arg ws "$INFISICAL_PROJECT_ID" --arg env "$INFISICAL_ENV_SLUG" \
              --arg sp "$SECRET_PATH" --arg v "$val" \
              '{workspaceId:$ws, environment:$env, secretPath:$sp, secretValue:$v}')
  # try create; on 400 (exists) fall back to update (PATCH)
  http=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "${INFISICAL_URL}/api/v3/secrets/raw/${key}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" -H 'Content-Type: application/json' -d "$body")
  if [ "$http" != "200" ]; then
    http=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH \
      "${INFISICAL_URL}/api/v3/secrets/raw/${key}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" -H 'Content-Type: application/json' -d "$body")
  fi
  [ "$http" = "200" ] || { echo "  !! Infisical write failed for ${key} (HTTP ${http})"; return 1; }
}

FAILED=0
while IFS=, read -r HOSTNAME MAC _; do
  # skip header / blanks / comments
  [[ -z "${HOSTNAME// }" || "$HOSTNAME" =~ ^# || "$HOSTNAME" == "hostname" ]] && continue
  HOSTNAME=$(echo "$HOSTNAME" | tr -d '[:space:]')
  MAC=$(echo "${MAC:-}" | tr -d '[:space:]' | tr 'a-f' 'A-F')

  SHORT=$(echo "$HOSTNAME" | cut -d. -f1)
  [ ${#SHORT} -le 15 ] || { echo "!! ${SHORT}: NetBIOS name >15 chars, skipping"; FAILED=1; continue; }

  KT="${KEYTAB_DIR}/${SHORT}.keytab"
  echo ">>> [${SHORT}] creating AD object + keytab..."
  rm -f "$KT"
  if ! printf '%s' "$AD_JOIN_PASS" | adcli join "$AD_DOMAIN" \
        --login-user="$AD_JOIN_USER" \
        --stdin-password \
        --computer-name="$SHORT" \
        --host-fqdn="${SHORT}.${AD_DOMAIN}" \
        --domain-ou="$AD_OU" \
        --host-keytab="$KT" \
        --show-details; then
    echo "  !! adcli join failed for ${SHORT}"; FAILED=1; continue
  fi
  chmod 600 "$KT"

  echo "    principals:"; klist -kt "$KT" | sed 's/^/      /'

  B64=$(base64 -w0 "$KT")
  KEY_HOST="KEYTAB_$(echo "$SHORT" | tr 'a-z-' 'A-Z_')"
  echo "    uploading ${KEY_HOST}..."
  upsert_secret "$KEY_HOST" "$B64" || FAILED=1

  # Varied hardware: servers may be cabled on any of several NICs. Column 2
  # accepts MULTIPLE semicolon-separated MACs; each becomes a vault alias
  # pointing at the same keytab + hostname.
  if [ -n "$MAC" ]; then
    IFS=';' read -ra MACLIST <<< "$MAC"
    for M in "${MACLIST[@]}"; do
      M_CLEAN=$(echo "$M" | tr -d ':-' | tr 'a-f' 'A-F')
      [ -n "$M_CLEAN" ] || continue
      KEY_MAC="KEYTAB_MAC_${M_CLEAN}"
      echo "    uploading ${KEY_MAC} (MAC fallback)..."
      upsert_secret "$KEY_MAC" "$B64" || FAILED=1
      # Also store hostname by MAC so the boot script can set the hostname
      upsert_secret "HOSTNAME_MAC_${M_CLEAN}" "$SHORT" || true
    done
  fi
done < "$CSV"

unset AD_JOIN_PASS
echo
if [ "$FAILED" -eq 0 ]; then
  echo "ALL HOSTS STAGED. Local keytab copies are in ${KEYTAB_DIR}/ — shred them once verified:"
  echo "  shred -u ${KEYTAB_DIR}/*.keytab"
else
  echo "COMPLETED WITH ERRORS — review output above."; exit 1
fi
