# /etc/sssd/sssd.conf — rendered by build-golden-image.sh
# Golden-image SSSD config: domain pre-configured, machine NOT joined at build.
# Identity arrives at boot via /etc/krb5.keytab injected by keytab-fetch.service.

[sssd]
domains = @@AD_DOMAIN@@
config_file_version = 2
services = nss, pam

[domain/@@AD_DOMAIN@@]
id_provider = ad
access_provider = ad
auth_provider = ad
chpass_provider = ad

ad_domain = @@AD_DOMAIN@@
krb5_realm = @@AD_REALM@@
realmd_tags = manages-system joined-with-adcli

krb5_keytab = /etc/krb5.keytab
ldap_sasl_authid = host/%(hostname)@@@AD_REALM@@

# ---------------------------------------------------------------- CRITICAL
# Stateless hosts must NEVER rotate the machine account password.
# The keytab in the vault is the single source of truth; rotation would
# desync the KVNO and break every subsequent boot. 0 = disabled.
ad_maximum_machine_account_password_age = 0
# ---------------------------------------------------------------------------

# Ephemeral OS: the SSSD cache lives in tmpfs and dies on reboot anyway.
# Keep credential caching on so users survive brief DC outages *within* a boot.
cache_credentials = True
krb5_store_password_if_offline = True

default_shell = /bin/bash
fallback_homedir = /home/%u@%d
use_fully_qualified_names = False

# ID mapping from SIDs (no POSIX attrs required in AD)
ldap_id_mapping = True

# DNS site discovery; pin a DC only if SRV records are unreliable in the lab:
# ad_server = @@DC_FQDN@@

dyndns_update = False
