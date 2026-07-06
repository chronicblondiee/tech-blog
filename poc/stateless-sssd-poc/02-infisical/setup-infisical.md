# Infisical Setup Runbook

## 1. Bring the stack up
```bash
cd 02-infisical
cp .env.example .env
# fill ENCRYPTION_KEY, AUTH_SECRET, POSTGRES_PASSWORD, SITE_URL
docker compose up -d
docker compose logs -f backend   # wait for "Server started"
```
Browse to `http://infisical.poc.lan:8080` → create the first admin account.

## 2. Create the project
1. **New Project** → name: `stateless-keytabs`.
2. Open the project → **Settings** → copy the **Project ID** (UUID). You'll need it in three places: `stage-keytabs.sh` env, `build-golden-image.sh` env, and troubleshooting.
3. Use the default `prod` environment. Create folder/secret-path `/keytabs` (Secrets → Add Folder).

## 3. Create Machine Identity: `baremetal-boot` (READ-ONLY, baked into image)
1. Org **Access Control** → **Identities** → **Create Identity** → name `baremetal-boot`, auth method **Universal Auth**.
2. Open the identity → Universal Auth → **Create Client Secret**. Record:
   - `CLIENT_ID`
   - `CLIENT_SECRET`
   - Recommended POC settings: Access Token TTL `300` s, Max TTL `300` s, unlimited uses. Optionally set a **Client Secret trusted IP range** = your bare-metal subnet (cheap hardening win).
3. Back in project `stateless-keytabs` → **Access Control** → **Add Identity** → `baremetal-boot` → role **Viewer** (read-only). If using granular permissions, scope read to secret path `/keytabs` on env `prod`.

## 4. Create Machine Identity: `keytab-stager` (READ/WRITE, used once from admin host)
Same steps, but attach with role **Developer**/write access to `/keytabs`. These credentials live only on the staging host; revoke or rotate the client secret after staging completes.

## 5. API smoke test
```bash
TOKEN=$(curl -s -X POST "$SITE_URL/api/v1/auth/universal-auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"clientId\":\"$CLIENT_ID\",\"clientSecret\":\"$CLIENT_SECRET\"}" | jq -r .accessToken)

# write (stager identity)
curl -s -X POST "$SITE_URL/api/v3/secrets/raw/SMOKETEST" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"workspaceId\":\"$PROJECT_ID\",\"environment\":\"prod\",\"secretPath\":\"/keytabs\",\"secretValue\":\"hello\"}"

# read (boot identity)
curl -s "$SITE_URL/api/v3/secrets/raw/SMOKETEST?workspaceId=$PROJECT_ID&environment=prod&secretPath=/keytabs" \
  -H "Authorization: Bearer $TOKEN" | jq -r .secret.secretValue   # -> hello
```
Delete `SMOKETEST` afterwards.

## Notes
- The API paths above (`/api/v1/auth/universal-auth/login`, `/api/v3/secrets/raw/...`) are Infisical's stable Universal Auth + raw secrets endpoints; if a newer image changes them, check `http://<host>:8080/api-docs`.
- For TLS: front with caddy (`caddy reverse-proxy --from https://infisical.poc.lan --to :8080`) and change `SITE_URL`/`INFISICAL_URL` everywhere to https.
