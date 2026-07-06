# /etc/krb5.conf — rendered by build-golden-image.sh
[libdefaults]
    default_realm = @@AD_REALM@@
    dns_lookup_realm = false
    dns_lookup_kdc = true
    rdns = false
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    default_ccache_name = KEYRING:persistent:%{uid}

[realms]
    @@AD_REALM@@ = {
        # KDCs discovered via DNS SRV records. Pin only if lab DNS is flaky:
        # kdc = @@DC_FQDN@@
        # admin_server = @@DC_FQDN@@
    }

[domain_realm]
    .@@AD_DOMAIN@@ = @@AD_REALM@@
    @@AD_DOMAIN@@ = @@AD_REALM@@
