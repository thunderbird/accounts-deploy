# Bringing up thunderbird-accounts on EKS — environment setup runbook

A living, end-to-end record of every step needed to stand up a working
`thunderbird-accounts` (Django web + Celery) environment on the Thunderbird Pro
EKS clusters, integrated with the Customer Auth Keycloak (`tbpro` realm).

Epic: [platform-infrastructure#144](https://github.com/thunderbird/platform-infrastructure/issues/144).

> **This repo is public.** This doc uses **generic placeholders only** — no real
> account IDs, endpoints, hostnames, or secret values. Resolve placeholders from
> the manifests, the Pulumi config in `platform-infrastructure`, or the AWS console.
>
> **Status:** `tb-dev` is up and login works end-to-end. Several pieces are
> temporary dev workarounds — see [§9](#9-temporary-workarounds--prod-hardening-todo).
> Update this doc as each step is finalized.

### Placeholder conventions

| Placeholder | Meaning |
|-------------|---------|
| `<ENV>` | environment: `tb-dev` or `tb-prod` |
| `<acct>` | the AWS account ID for `<ENV>` (see `platform-infrastructure` CLAUDE.md) |
| `<region>` | the AWS region the clusters run in |
| `<ecr>` | per-account ECR registry, `<acct>.dkr.ecr.<region>.amazonaws.com` |
| `<tailnet>` | the org Tailscale MagicDNS suffix |
| `<accounts-host>` | `https://accounts-<ENV>.<tailnet>` |
| `<keycloak-host>` | `https://keycloak-customer-<ENV>.<tailnet>` (front-channel) |
| `<keycloak-svc>` | `http://keycloak-customer.keycloak-customer.svc.cluster.local` (in-cluster, back-channel) |
| `<rds-endpoint>` | the accounts RDS Postgres endpoint |
| `<neon-endpoint>` | the Keycloak Neon branch DB endpoint (dev) |
| `<public-host>` | the prod public hostname at cutover (e.g. the auth/accounts host on the prod domain) |

---

## 0. Prerequisites

| Thing | Value |
|-------|-------|
| Clusters | `mzla-eks-<ENV>01` (`<acct>`, `<region>`, arm64/Graviton) |
| ArgoCD hub | the shared-services cluster, namespace `argocd` |
| kubectl contexts | `tb-dev`, `tb-prod`, `shared01` |
| AWS SSO profiles | `mzla-tb-dev`, `mzla-tb-prod`, `mzla-legacy` (image ECR + stage Secrets Manager) |
| Namespaces | `accounts`, `keycloak-customer` |

Refresh SSO before any cluster/AWS op (tokens expire daily):

```bash
aws sso login --profile mzla-<ENV>      # + mzla-legacy as needed
```

Repos involved:

- **accounts-deploy** (this repo) — Kustomize manifests for the app + ACK data stores.
- **thunderbird-accounts** — the app source, the Keycloak image, and the `tbpro` theme.
- **keycloak-customer-deploy** — Kustomize for the Customer Auth Keycloak.
- **platform-infrastructure** — Pulumi (IRSA, pod SGs, ECR mirror) + the ArgoCD `Application`/`AppProject` definitions. *(Private; keep concrete values there.)*

---

## 1. Image: multi-arch build + ECR availability

The clusters are arm64 (Graviton); the app image must be multi-arch.

- `thunderbird-accounts` CI builds the `accounts` image (buildx `linux/amd64,linux/arm64`).
- The image is mirrored into the per-account ECR so the nodes can pull it:
  `<ecr>/accounts:<tag>` (the Keycloak image is `<ecr>/keycloak-customer:<tag>`).
- Pin the tag in `overlays/<ENV>/kustomization.yaml` under `images:`.

> Tracked by platform-infrastructure#593 (image) / #558 (keycloak mirror).
> Verify multi-arch: `docker manifest inspect <ecr>/accounts:<tag>` shows amd64 + arm64.

---

## 2. Networking: IRSA + pod Security Groups (Pulumi)

In `platform-infrastructure/pulumi/environments/mzla-<ENV>`:

- An `accounts` pod SecurityGroupPolicy (strict mode) assigning a pod SG whose egress
  reaches: **RDS :5432**, **Redis :6379**, **Keycloak :8080** (in-cluster), **Secrets
  Manager (HTTPS)**, and the **Stalwart mgmt API**.
- A reciprocal ingress rule on the Keycloak pod SG allowing the accounts pod SG → 8080.

Apply from the feature branch and confirm pod ENIs carry the accounts SG before merging.
Missing egress shows up as silent connection timeouts, not errors.

---

## 3. Data stores: net-new ACK RDS + ElastiCache (no data migration)

All new infra, provisioned via ACK CRs in `bases/aws/` (migrate real data at cutover):

- `db-instance.yaml` — RDS Postgres (`accounts` DB/user).
- `elasticache.yaml` — Redis (broker + cache + result backend).
- `subnet-groups.yaml`, `security-groups.yaml` — ACK-managed networking.
- `field-exports.yaml` — ACK `FieldExport`s that publish the live endpoints into
  ConfigMaps the app reads:
  - `accounts-db-endpoint` → `DATABASE_HOST`, `DATABASE_PORT`
  - (Redis endpoint similarly; the connection **URL** itself is a secret — see §4.)

> **FieldExport gotcha:** the ConfigMap starts with `pending-field-export` and is
> populated only when the ACK controller reconciles. The ArgoCD `Application` must
> `ignoreDifferences` those ConfigMap keys **with `RespectIgnoreDifferences=true`**,
> and manual syncs must not drop that syncOption (or the value reverts). Pods that
> started before the endpoint populated keep the stale `pending-field-export` value
> and must be **restarted** (`kubectl rollout restart deploy/...`).

---

## 4. Secrets: AWS Secrets Manager + ExternalSecrets (ESO)

Two `ExternalSecret`s in `bases/accounts/externalsecret.yaml` (overlay repoints the
SM paths to `mzla/<ENV>/...`):

| ExternalSecret | Target k8s secret | SM source | Contents |
|----------------|-------------------|-----------|----------|
| `accounts-secrets` | `accounts-secrets` | `mzla/<ENV>/accounts` (whole-secret `dataFrom`) | app secret bundle — see §11.4 for the key list |
| `accounts-db` | `accounts-db` | `mzla/<ENV>/accounts-db` (`username`, `password`) | RDS credentials |

To **add/merge keys** into the SM bundle (e.g. Paddle test keys) **without printing
them**: fetch the current JSON, merge the new keys from a local file, put it back —
piping blind, never `cat`-ing the value. ESO resyncs within the refresh interval (1h)
or on a forced `Reconcile`.

Verify: `kubectl -n accounts get externalsecret` → all `SecretSynced/Ready=True`.

> **prod:** `mzla/tb-prod/accounts` must be **created** before the prod app can boot
> (it does not exist yet) — include `REDIS_URL` pointing at the prod ElastiCache primary.

---

## 5. App config (non-secret)

`bases/accounts/configmap.yaml` + `overlays/<ENV>/.../configmap.yaml`. Key choices:

- **`APP_ENV: stage`** (not `dev`). `dev` makes Django treat the request as local
  HTTP and disables `SECURE_PROXY_SSL_HEADER`, so it ignores the ingress
  `X-Forwarded-Proto` and emits `http://` OIDC `redirect_uri`s that Keycloak rejects.
- **OIDC URLs are split:** front-channel (browser redirects) use `<keycloak-host>`;
  back-channel (token/userinfo/jwks + admin API) use `<keycloak-svc>`, since the pod
  can't resolve the tailnet MagicDNS name.
- `REDIS_*_DB` logical DB indices are config; the `REDIS_URL` is a secret.
- **`ALLOWED_HOSTS` must be set per env.** Empty → Django `DisallowedHost` 400 on
  every request (incl. the readiness probe, whose Host is the pod IP) → pods never
  go Ready. Dev uses `*`; **prod must pin it** to `<public-host>` and set
  `CSRF_TRUSTED_ORIGINS` accordingly.

---

## 6. ArgoCD Application + AppProject

In `platform-infrastructure/argocd/`:

- `argocd/projects/<ENV>-accounts.yaml` — AppProject (sourceRepos: accounts-deploy).
- `argocd/<ENV>/apps/accounts.yaml` — `Application` (namespace `accounts`,
  `ServerSideApply=true`, `RespectIgnoreDifferences=true`, `ignoreDifferences` for the
  FieldExport ConfigMap keys + ESO-managed fields).

ArgoCD runs on the hub (`shared01`) and manages the remote clusters. Trigger a sync:

```bash
kubectl --context shared01 -n argocd annotate application <ENV>-accounts \
  argocd.argoproj.io/refresh=hard --overwrite
```

> `<ENV>-accounts` apps have **no `automated`/selfHeal** — first adoption needs a
> deliberate manual sync. `tb-prod-accounts` is currently OutOfSync (app layer never applied).

---

## 7. OIDC client wiring (tbpro realm on the Customer Auth Keycloak)

The `thunderbird-accounts` client in the `tbpro` realm needs the EKS URLs registered:

- **Valid redirect URIs:** `<accounts-host>/*` (login callback).
- **Valid post-logout redirect URIs:** `<accounts-host>/logout/callback`
  — **required**, or RP-initiated logout returns `400 Invalid redirect uri`.

> ⚠️ The `thunderbird-accounts` client currently exists **only as live Keycloak DB
> state** (the dev DB is a Neon branch clone of stage) — it is **codified nowhere**
> (the realm import has only stub clients). Edits are made live via the admin API
> (see §10). This is a DR gap and the root cause of the logout 400. **TODO:** codify
> the client (redirect + post-logout URIs, MFA flow) via keycloak-config-cli / realm
> import, including the prod public host.

---

## 8. Validation checklist

```bash
# pods healthy
kubectl --context <ENV> -n accounts get pods           # web + celery Running
kubectl --context <ENV> -n keycloak-customer get pods  # 2 keycloak replicas Ready

# DB host actually wired (not pending-field-export)
kubectl --context <ENV> -n accounts exec <web-pod> -- printenv DATABASE_HOST

# celery connected to the broker (no DB/redis resolution errors)
kubectl --context <ENV> -n accounts logs deploy/accounts-celery --tail=30

# login: browser to <accounts-host> -> Keycloak -> back
# logout: the /logout button should round-trip (see §7)
```

- **Admin panel:** `<accounts-host>/admin/` (Django admin), gated on `is_superuser`
  + `is_staff`. Grant via the `make_superuser` command (§10) or the `is_services_admin`
  OIDC attribute mapped in the app middleware.

---

## 9. Temporary workarounds & prod hardening (TODO)

These keep **dev** working but must be resolved before the prod cutover (#142):

| Workaround (dev) | Why | Durable fix |
|------------------|-----|-------------|
| StatefulSet `command` override forcing `--proxy-headers xforwarded` | The Tailscale ingress sends only `X-Forwarded-*`, but the image entrypoint hardcodes `--proxy-headers forwarded` (the CLI flag wins over `KC_PROXY_HEADERS`). Keycloak then sees a **non-secure context** → sets `AUTH_SESSION_ID` `SameSite=None` **without `Secure`** → the browser drops it → login **400 "Cookie not found"**. | **Cutover ingress/LB design** (platform-infrastructure#142): front Keycloak so it sees HTTPS directly (TLS passthrough / HTTPS backend) → the proxy-headers mode is moot. *(If the LB instead terminates TLS and forwards HTTP + `X-Forwarded-Proto`, Keycloak must run `xforwarded`.)* |
| `ALLOWED_HOSTS: "*"` (dev) | dev convenience | pin `ALLOWED_HOSTS` + `CSRF_TRUSTED_ORIGINS` to `<public-host>` for prod |
| Live Keycloak client edits (redirect / post-logout URIs) | branch DB, done by hand | codify in realm config (§7) |
| Moving `quay.io/keycloak/keycloak:26.5` base tag | non-reproducible builds (silently tracks the latest `26.5.x`) | pin `Dockerfile.keycloak` to a specific patch / digest (both stages) |
| Neon-branch dev DB | fast dev clone | prod uses the net-new ACK RDS, migrate at cutover |
| prod app layer not deployed; `mzla/tb-prod/accounts` secret missing | validation phase | create the secret, then sync `tb-prod-accounts` |
| prod cutover files staged-but-unreferenced (cloudflare-tunnel, admin-ingress, PDB minAvailable=2) | validation phase | at cutover: reference them, flip `KC_HOSTNAME`→`<public-host>`, set `KC_HOSTNAME_ADMIN`, scale to 3 replicas |

> **Corrected root cause (this was misdiagnosed earlier).** The dev login 400 was
> **"Cookie not found"** — the auth-session cookie wasn't being stored, because of
> the non-secure proxy context in the first row — **not** the tbpro theme
> HTML-escaping the loginAction (`&amp;`). The `&amp;` is harmless: Keycloak recovers
> `execution` from the cookie, and `auth-stage.tb.pro` renders the identical `&amp;`
> and logs in fine. Proven by a three-way test (good `&` + cookie → 200; `&amp;` +
> cookie → 200 identical; good `&` + no cookie → **400 "Cookie not found"**). The
> earlier theme `?no_esc` override (a `patch-login-theme` initContainer) was removed
> (keycloak-customer-deploy#11), thunderbird-accounts PR #1030 was dropped, and the
> entrypoint-fix issue (#1037) was closed in favor of the cutover LB design. The
> **only** load-bearing dev Keycloak override is now `--proxy-headers xforwarded`.

---

## 10. Operational recipes

### Reset a dev user's password (Neon-branch Keycloak, no usable env admin)

The env `KC_BOOTSTRAP_ADMIN_*` isn't valid on the branch DB. Mint a throwaway admin
via `kc.sh bootstrap-admin user` (DB-direct, with cache/port overrides so it doesn't
clash with the running server), reset, then delete the throwaway admin. The new
password is generated locally and piped to the pod over **stdin** (never in args/logs):

```bash
TEMP=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
printf '%s\n' "$TEMP" > /tmp/dev-pw.txt; chmod 600 /tmp/dev-pw.txt
printf '%s\n' "$TEMP" | kubectl --context tb-dev -n keycloak-customer exec -i keycloak-customer-0 -c keycloak -- bash -lc '
  set -e; IFS= read -r T
  KC=/opt/keycloak/bin/kc.sh; KCADM=/opt/keycloak/bin/kcadm.sh
  TADMIN="tmpadmin$(tr -dc 0-9 </dev/urandom | head -c4)"; export TAPW=$(tr -dc A-Za-z0-9 </dev/urandom | head -c24)
  KC_CACHE=local KC_HTTP_PORT=8123 KC_HTTP_MANAGEMENT_PORT=9123 "$KC" bootstrap-admin user --no-prompt --username "$TADMIN" --password:env TAPW >/dev/null 2>&1
  "$KCADM" config credentials --server http://localhost:8080 --realm master --user "$TADMIN" --password "$TAPW" >/dev/null
  TGT=$("$KCADM" get users -r tbpro -q username=<USER> --fields id --format csv --noquotes | head -1)
  "$KCADM" set-password -r tbpro --userid "$TGT" --new-password "$T" --temporary
  MID=$("$KCADM" get users -r master -q username="$TADMIN" --fields id --format csv --noquotes | head -1)
  "$KCADM" delete users/"$MID" -r master
'
# read it once, then: shred -u /tmp/dev-pw.txt
```

> The image has no `curl`/`tar` (so `kubectl cp` fails); use `kcadm.sh` in-pod + stdin.

### Make a Django superuser (admin panel access)

```bash
kubectl --context <ENV> -n accounts exec deploy/accounts-web -- \
  /app/.venv/bin/python /app/manage.py make_superuser <email>
```

> `<email>` must match an **existing** Django user (created on first OIDC login,
> keyed on the Keycloak username). List users:
> `… manage.py shell -c "from django.contrib.auth import get_user_model as g; [print(u.get_username()) for u in g().objects.all()]"`.

---

## 11. Reference inventory — every parameter / secret / URL

Single source of truth for the **shape** of the config. **No real values, endpoints,
account IDs, or secret values** — placeholders only (resolve from the manifests /
`platform-infrastructure` / AWS console). Same shape for both envs (`mzla/<ENV>/*`).

### 11.1 Identifiers / endpoints (all placeholders)

| Thing | Reference |
|-------|-----------|
| Cluster | `mzla-eks-<ENV>01` (acct `<acct>`, `<region>`, arm64) |
| Accounts image | `<ecr>/accounts:<tag>` |
| Keycloak image | `<ecr>/keycloak-customer:<tag>` |
| Accounts public URL | `<accounts-host>` |
| Keycloak front-channel (browser) | `<keycloak-host>` |
| Keycloak back-channel (in-cluster) | `<keycloak-svc>` (svc :80 → 8080) |
| Realm / OIDC client | `tbpro` / `thunderbird-accounts` |
| RDS (accounts) | `<rds-endpoint>:5432`, db `accounts`, user `accounts` |
| Keycloak DB (dev) | Neon **branch** clone of stage, `<neon-endpoint>` (DIRECT, `sslmode=require`) |

### 11.2 ConfigMap `accounts-config` (non-secret env)

| Key | Value / reference | Notes |
|-----|-------------------|-------|
| `APP_ENV` | `stage` | NOT `dev` (see §5) |
| `APP_DEBUG` | `False` | |
| `LOG_LEVEL` | `INFO` | |
| `AUTH_SCHEME` | `oidc` | |
| `PUBLIC_BASE_URL` | `<accounts-host>` | |
| `ALLOWED_HOSTS` | `*` (dev) / `<public-host>` (prod) | **pin for prod** |
| `CSRF_TRUSTED_ORIGINS` | `<accounts-host>` | |
| `CSRF_SECURE` / `CSRF_HTTPONLY` | `True` / `True` | |
| `ALLOWED_EMAIL_DOMAINS` | `thundermail.com,tb.pro` | |
| `OIDC_CLIENT_ID` | `thunderbird-accounts` | secret is `OIDC_CLIENT_SECRET` |
| `OIDC_SIGN_ALGO` | `RS256` | |
| `OIDC_URL_AUTH` / `OIDC_URL_LOGOUT` | `<keycloak-host>/realms/tbpro/protocol/openid-connect/{auth,logout}/` | **front-channel** |
| `OIDC_URL_TOKEN` / `OIDC_URL_USER` / `OIDC_URL_JWKS` | `<keycloak-svc>/realms/tbpro/protocol/openid-connect/{token,userinfo,certs}/` | **back-channel** |
| `KEYCLOAK_URL_API` | `<keycloak-svc>/admin/realms/tbpro` | admin API |
| `KEYCLOAK_ADMIN_URL_TOKEN` | `<keycloak-svc>/realms/tbpro/protocol/openid-connect/token/` | admin token |
| `DATABASE_NAME` / `DATABASE_USER` | `accounts` / `accounts` | host/port via FieldExport (§11.3) |
| `REDIS_INTERNAL_DB` / `REDIS_CELERY_DB` / `REDIS_CELERY_RESULTS_DB` / `REDIS_SHARED_DB` | `0` / `5` / `6` / `10` | URL is a secret (`REDIS_URL`) |
| `HOSTED_DKIM_CLOUDFLARE_ENABLED` | `true` | token = secret |
| `HOSTED_DKIM_DOMAIN` | `dkim.thunderhosted.com` | |
| `HOSTED_DKIM_SELECTORS` | `tm1,tm2,tm3` | |
| `STALWART_API_AUTH_METHOD` | `bearer` | |
| `STALWART_BASE_API_URL` | `<stalwart-api-url>` | ⚠️ **still a placeholder in dev** |

### 11.3 FieldExport-populated ConfigMap `accounts-db-endpoint`

| Key | Value | Source |
|-----|-------|--------|
| `DATABASE_HOST` | `<rds-endpoint>` | ACK `FieldExport` from the RDS DBInstance |
| `DATABASE_PORT` | `5432` | same |

### 11.4 Secrets — `mzla/<ENV>/accounts` (ExternalSecret `accounts-secrets`)

Whole-secret `dataFrom`. **Key names only — no values.** (Same list is in
`bases/accounts/externalsecret.yaml`.)

| Key | Purpose | dev status |
|-----|---------|------------|
| `SECRET_KEY` | Django secret key | set |
| `LOGIN_CODE_SECRET` | login-code signing | set |
| `OIDC_CLIENT_SECRET` | OIDC client secret (tbpro) | set |
| `KEYCLOAK_ADMIN_CLIENT_ID` / `KEYCLOAK_ADMIN_CLIENT_SECRET` | admin API (client-credentials) | set |
| `REDIS_URL` | Redis connection URL (broker/cache/results) | set |
| `PADDLE_API_KEY` / `PADDLE_TOKEN` / `PADDLE_WEBHOOK_KEY` | Paddle billing | ⚠️ **EMPTY** |
| `PADDLE_PRICE_ID_LO` / `PADDLE_PRICE_ID_MD` / `PADDLE_PRICE_ID_HI` | Paddle price IDs | ⚠️ **EMPTY** |
| `STALWART_API_AUTH_STRING` / `STALWART_WEBHOOK_SECRET` | Stalwart mgmt + webhook | set |
| `MAILCHIMP_API_KEY` / `MAILCHIMP_DC` / `MAILCHIMP_LIST_ID` | Mailchimp | set |
| `ZENDESK_API_TOKEN` / `ZENDESK_SUBDOMAIN` / `ZENDESK_USER_EMAIL` | Zendesk | set |
| `HOSTED_DKIM_CLOUDFLARE_API_TOKEN` | Cloudflare DKIM | set |
| `SENTRY_DSN` | Sentry | set |
| `POSTHOG_API_KEY` | PostHog | set |

### 11.5 Secrets — `mzla/<ENV>/accounts-db` (ExternalSecret `accounts-db`)

| Key | Purpose |
|-----|---------|
| `username` | RDS user |
| `password` | RDS password |

### 11.6 URLs to register on the Keycloak `thunderbird-accounts` client (tbpro realm)

| Setting | Value | Status |
|---------|-------|--------|
| Valid redirect URIs | `<accounts-host>/*` (login `…/oidc/callback/`) | registered (#599) |
| Valid **post-logout** redirect URIs | `<accounts-host>/logout/callback` | ⚠️ **MISSING → logout 400** |
| Web origins | `<accounts-host>` | verify |

### 11.7 Open value gaps

- `PADDLE_*` (6 keys) — empty; need test/sandbox values.
- `STALWART_BASE_API_URL` — placeholder.
- Keycloak post-logout redirect URI — not yet registered.
- prod: `mzla/tb-prod/accounts` secret missing; prod app layer not yet synced.

---

## 12. Target production design (endpoints, observability)

Not built yet — the agreed target shape. Net-new items are candidates for sub-issues
under platform-infrastructure#144.

### 12.1 Customer-facing endpoints: load balancer + DNS

- Each customer-facing service (accounts at `<public-host>`, Customer Auth at the auth
  host) is fronted by a public **AWS load balancer** + a **DNS record on Cloudflare**
  (the customer domains live in Cloudflare).
- **DNS is not codified in-cluster yet.** The existing `external-dns`
  (`platform-infrastructure: argocd/apps/external-dns.yaml`) runs on the shared-services cluster
  with **`provider: aws` (Route53)** scoped to an internal Route53 zone — it does **not**
  manage Cloudflare.
- **Net-new: add a Cloudflare-provider `external-dns`** to `mzla-eks-tb-{dev,prod}`:
  - Cloudflare API token via ESO (mirror `argocd/resources/cloudflare-externalsecret.yaml`).
  - per-cluster `txtOwnerId` (e.g. `mzla-eks-tb-<env>01`), `domainFilters` scoped to the
    customer zone, `policy: sync`, `sources: [service, ingress]`.
  - writes/updates Cloudflare records pointing at the LBs from Service/Ingress annotations.
- Already in the org as an alternative: `cloudflare-tunnel-operator` (argocd/grafana; staged
  for prod keycloak via `cloudflare-tunnel.yaml`). **Decision: LB + external-dns** for
  customer traffic (a normal public LB endpoint), not a tunnel.
- **Secure-context tie-in (cookies):** the LB TLS mode is the durable resolution of the
  dev `--proxy-headers xforwarded` workaround (§9). TLS passthrough / HTTPS backend →
  Keycloak sees HTTPS directly → no `--proxy-headers` dependency. Terminate-TLS +
  forward HTTP → Keycloak must keep `xforwarded`.

### 12.2 Admin / staff surfaces: split to Tailscale (private)

- **Accounts admin** is Django admin under the **`/admin/*`** path (hardcoded in
  `urls.py`; includes the custom `admin/authentication/...import...` routes), plus the
  staff route **`/mail/admin/stalwart/`**. Same app/pod — not a separate service.
- Split at the **edge**, not the app:
  - Public LB ingress serves customer paths and **denies `/admin*` and `/mail/admin*`**.
  - A **Tailscale ingress** routes to the accounts Service so staff reach admin only over
    the tailnet — mirroring the Customer Auth Keycloak's `tailscale-admin-ingress.yaml` +
    `KC_HOSTNAME_ADMIN` (public `/admin` denied at the edge).
  - App-level `is_staff` / `is_superuser` gating stays as defense-in-depth.

### 12.3 Flower (Celery monitoring) — recreate from legacy

- Legacy runs `flower-{stage,prod}` ECS (Flower UI, port **5555**, `TBA_FLOWER=yes` →
  `celery … flower`), behind an LB (e.g. `flower.<domain>`).
- EKS net-new: a `flower` Deployment (`TBA_FLOWER=yes`, same image, single replica) +
  Service (5555) + a **Tailscale ingress** (staff-only — Flower exposes broker internals,
  **never public**; not behind the customer LB).

### 12.4 Observability environments: Sentry + PostHog

- **Single knob:** set **`APP_ENV=mzla-tb-dev`** (dev) / **`APP_ENV=mzla-tb-prod`** (prod),
  replacing the current `APP_ENV=stage` on tb-dev (which mixes EKS-dev into the real
  `stage` streams).
- **Verified safe** — nothing branches on `APP_ENV`/`IS_STAGE`/`IS_PROD` for behavior
  (only `settings.py` for Sentry/DEBUG, and `telemetry/client.py` passes `APP_ENV` as the
  env tag), and secure-proxy is gated on `not IS_DEV`, so any non-`dev` value keeps the
  HTTPS redirect-URI behavior. This **un-parks** the earlier APP_ENV question.
- One knob sets **both**:
  - **Sentry**: `sentry_sdk.init(environment=APP_ENV)` → `mzla-tb-dev` / `mzla-tb-prod`.
    Create those environments in Sentry.
  - **PostHog**: `telemetry/client.py` tags events with `environment: APP_ENV` → same env.
    Set `POSTHOG_API_KEY` per env in SM (new project, or shared project distinguished by
    the env tag); `POSTHOG_HOST` defaults to `https://us.i.posthog.com`.

### 12.5 Net-new work items (candidate #144 sub-issues)

- Cloudflare-provider `external-dns` on tb-{dev,prod} → codified customer DNS
- public LB + DNS records for accounts + Customer Auth
- admin/staff split to Tailscale (accounts) + edge-deny of `/admin`
- Flower Deployment + tailnet ingress
- flip `APP_ENV` → `mzla-tb-{dev,prod}`; create Sentry envs + per-env PostHog keys
