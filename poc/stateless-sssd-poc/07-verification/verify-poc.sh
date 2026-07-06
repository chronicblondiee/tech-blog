#!/usr/bin/env bash
# verify-poc.sh — run as root ON A DEPLOYED PHYSICAL NODE.
# Validates every layer of the stateless SSSD architecture.
# Usage: ./verify-poc.sh [ad_test_username]
set -uo pipefail

TEST_USER="${1:-}"
PASS=0; FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "  [....] $*"; }

REALM=$(awk -F'= *' '/krb5_realm/ {print $2}' /etc/sssd/sssd.conf 2>/dev/null | tr -d ' ')
HOSTN=$(hostname -s)

echo "== 1. Stateless root =="
if mount | grep -qE 'LiveOS|/run/rootfsbase|overlay on / '; then
  ok "root is a live RAM overlay (PXE RAM-boot)"
elif mount | grep -qE 'overlay on / | / .*\bro\b' || grep -q systemd.volatile=overlay /proc/cmdline; then
  ok "root is volatile-overlay/read-only (disk-deploy fallback: systemd.volatile=overlay)"
else
  bad "no overlay on / — writes will persist (check boot.ipxe args / overlayroot.conf)"
fi
if grep -q 'root=live:' /proc/cmdline 2>/dev/null; then
  ok "booted via livenet: $(grep -o 'root=live:[^ ]*' /proc/cmdline)"
  grep -q 'rd.live.ram=1' /proc/cmdline && ok "image fully copied to RAM (rd.live.ram=1)" \
    || bad "rd.live.ram=1 missing — node keeps a network dependency on the PXE server"
fi

echo "== 2. Time sync (Kerberos prerequisite) =="
if chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal'; then
  ok "chrony synchronized"
else
  bad "chrony not synchronized — kinit will fail on >5min skew"
fi

echo "== 3. Keytab fetch =="
if systemctl is-active --quiet keytab-fetch.service; then
  ok "keytab-fetch.service active (oneshot completed)"
else
  bad "keytab-fetch.service not active — see: journalctl -u keytab-fetch; cat /run/keytab-fetch.log"
fi
if [ -s /etc/krb5.keytab ]; then
  ok "/etc/krb5.keytab present ($(stat -c '%a %U:%G' /etc/krb5.keytab))"
  if klist -kt /etc/krb5.keytab | grep -qi "${HOSTN}\\\$@"; then
    ok "keytab contains ${HOSTN}\$ principal"
  else
    bad "keytab principals don't match hostname ${HOSTN}"
  fi
else
  bad "/etc/krb5.keytab missing/empty"
fi

echo "== 4. Machine identity vs KDC =="
if KRB5CCNAME=MEMORY: kinit -kt /etc/krb5.keytab "$(echo "$HOSTN" | tr 'a-z' 'A-Z')\$@${REALM}" 2>/tmp/kinit.err; then
  ok "kinit -k as machine account succeeded"
else
  bad "kinit failed: $(cat /tmp/kinit.err)"
fi

echo "== 5. SSSD health =="
if systemctl is-active --quiet sssd; then
  ok "sssd running"
else
  bad "sssd not running"
fi
if command -v sssctl >/dev/null; then
  DOM=$(sssctl domain-list 2>/dev/null | head -1)
  if [ -n "$DOM" ] && sssctl domain-status "$DOM" 2>/dev/null | grep -qi 'Online status: Online'; then
    ok "domain ${DOM} Online"
  else
    bad "SSSD domain offline — check DNS SRV: dig SRV _ldap._tcp.${DOM,,}"
  fi
fi

echo "== 6. AD user resolution =="
if [ -n "$TEST_USER" ]; then
  if id "$TEST_USER" >/dev/null 2>&1; then
    ok "id ${TEST_USER} resolved: $(id "$TEST_USER" | cut -c1-90)"
  else
    bad "id ${TEST_USER} failed"
  fi
else
  info "skipped (pass an AD username: ./verify-poc.sh jdoe)"
fi

echo "== 7. Single AD object sanity =="
if command -v adcli >/dev/null && KRB5CCNAME=MEMORY: adcli show-computer --domain "$(awk -F'= *' '/ad_domain/ {print $2}' /etc/sssd/sssd.conf | tr -d ' ')" --login-type=computer "$HOSTN" >/dev/null 2>&1; then
  ok "computer object ${HOSTN} visible in AD (authenticated via own keytab)"
else
  info "adcli show-computer inconclusive — verify in ADUC: exactly ONE object named ${HOSTN}"
fi

echo "== 8. Statelessness canary =="
if [ -f /root/.poc-canary ]; then
  bad "canary from previous boot SURVIVED — root is NOT stateless"
  rm -f /root/.poc-canary
else
  touch /root/.poc-canary
  info "canary planted at /root/.poc-canary — reboot and re-run; step 8 must not FAIL"
fi

echo
echo "RESULT: ${PASS} passed, ${FAIL} failed"
echo "POC acceptance = two consecutive clean runs across a reboot with FAIL=0."
[ "$FAIL" -eq 0 ]
