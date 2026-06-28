# Bringing up thunderbird-accounts on EKS — environment setup runbook

A living, end-to-end record of every step needed to stand up a working
`thunderbird-accounts` (Django web + Celery) environment on the Thunderbird Pro
EKS clusters, integrated with the Customer Auth Keycloak (`tbpro` realm).

Epic: [platform-infrastructure#144](https://github.com/thunderbird/platform-infrastructure/issues/144).

> **Status:** `tb-dev` is up and login works end-to-end. Several pieces are
> temporary dev workarounds — see [§9 Temporary workarounds & prod hardening](#9-temporary-workarounds--prod-hardening-todo).
> Update this doc as each step is finalized.

---

## 0. Prerequisites

| Thing | Value |
|-------|-------|
| Clusters | `mzla-eks-tb-dev01` (718959508124), `mzla-eks-tb-prod01` (689951664252), eu-central-1, arm64/Graviton |
| ArgoCD hub | `mzla-eks-shared01` (826971876779, us-east-1), namespace `argocd` |
| kubectl contexts | `tb-dev`, `tb-prod`, `shared01` |
| AWS SSO profiles | `mzla-tb-dev`, `mzla-tb-prod`, `mzla-legacy` (image ECR + stage Secrets Manager) |
| Namespaces | `accounts`, `keycloak-customer` |

Refresh SSO before any cluster/AWS op (tokens expire daily):

```bash
aws sso login --profile mzla-tb-dev      # + mzla-tb-prod / mzla-legacy as needed
```

Repos involved:

- **accounts-deploy** (this repo) — Kustomize manifests for the app + ACK data stores.
- **thunderbird-accounts** — the app source, the Keycloak image, and the `tbpro` theme.
- **keycloak-customer-deploy** — Kustomize for the Customer Auth Keycloak.
- **platform-infrastructure** — Pulumi (IRSA, pod SGs, ECR mirror) + the ArgoCD `Application`/`AppProject` definitions.

---

## 1. Image: multi-arch build + ECR availability

The clusters are arm64 (Graviton); the app image must be multi-arch.

- `thunderbird-accounts` CI builds the `accounts` image (buildx `linux/amd64,linux/arm64`).
- The image is mirrored into the per-account ECR so the EKS nodes can pull it.
  - tb-dev: `718959508124.dkr.ecr.eu-central-1.amazonaws.com/accounts:<tag>`
  - The Keycloak image lives at `…/keycloak-customer:<tag>` (same pattern).
- Pin the tag in `overlays/<env>/kustomization.yaml` under `images:`.

> Tracked by platform-infrastructure#593 (image) / #558 (keycloak mirror).
> Verify multi-arch: `docker manifest inspect <ecr>/accounts:<tag>` shows amd64 + arm64.

---

## 2. Networking: IRSA + pod Security Groups (Pulumi)

In `platform-infrastructure/pulumi/environments/mzla-tb-{dev,prod}`:

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
SM paths to `mzla/<env>/...`):

| ExternalSecret | Target k8s secret | SM source | Contents |
|----------------|-------------------|-----------|----------|
| `accounts-secrets` | `accounts-secrets` | `mzla/<env>/accounts` (whole-secret `dataFrom`) | `SECRET_KEY`, `LOGIN_CODE_SECRET`, `REDIS_URL`, OIDC client secret, Keycloak admin creds, Paddle, Stalwart, Sentry/PostHog, … |
| `accounts-db` | `accounts-db` | `mzla/<env>/accounts-db` (`username`, `password`) | RDS credentials |

To **add/merge keys** into the SM bundle (e.g. Paddle test keys) **without printing
them**: fetch the current JSON, merge the new keys from a local file, put it back —
piping blind, never `cat`-ing the value. ESO resyncs within the refresh interval (1h)
or on a forced `Reconcile`.

Verify: `kubectl -n accounts get externalsecret` → all `SecretSynced/Ready=True`.

---

## 5. App config (non-secret)

`bases/accounts/configmap.yaml` + `overlays/<env>/.../configmap.yaml`. Key choices:

- **`APP_ENV: stage`** (not `dev`). `dev` makes Django treat the request as local
  HTTP and disables `SECURE_PROXY_SSL_HEADER`, so it ignores the ingress
  `X-Forwarded-Proto` and emits `http://` OIDC `redirect_uri`s that Keycloak rejects.
- **OIDC URLs are split:** front-channel (browser redirects) use the **tailnet host**
  (`keycloak-customer-<env>.tail2726a2.ts.net`); back-channel (token/userinfo/jwks +
  admin API) use the **in-cluster Service** (`keycloak-customer.keycloak-customer.svc.cluster.local`),
  since the pod can't resolve the tailnet MagicDNS name.
- `REDIS_*_DB` logical DB indices are config; the `REDIS_URL` is a secret.
- `ALLOWED_HOSTS: "*"` is **dev-only** (kubelet probe uses the pod IP as Host) — **pin it for prod**.

---

## 6. ArgoCD Application + AppProject

In `platform-infrastructure/argocd/`:

- `argocd/projects/<env>-accounts.yaml` — AppProject (sourceRepos: accounts-deploy).
- `argocd/<env>/apps/accounts.yaml` — `Application` (namespace `accounts`,
  `ServerSideApply=true`, `RespectIgnoreDifferences=true`, `ignoreDifferences` for the
  FieldExport ConfigMap keys + ESO-managed fields).

ArgoCD runs on `shared01` and manages the remote clusters. Trigger a sync after a merge:

```bash
kubectl --context shared01 -n argocd annotate application <env>-accounts \
  argocd.argoproj.io/refresh=hard --overwrite
```

---

## 7. OIDC client wiring (tbpro realm on the Customer Auth Keycloak)

The `thunderbird-accounts` client in the `tbpro` realm needs the EKS URLs registered:

- **Valid redirect URIs:** `https://accounts-<env>.tail2726a2.ts.net/*` (login callback).
- **Valid post-logout redirect URIs:** `https://accounts-<env>.tail2726a2.ts.net/logout/callback`
  — **required**, or RP-initiated logout returns `400 Invalid redirect uri`.

> The dev Keycloak DB is a **Neon branch clone of stage**, so these client edits are
> currently made **live via the admin API** on the branch (see §10 recipes). They are
> NOT yet codified — a prod cutover needs them in realm config (keycloak-config-cli).

---

## 8. Validation checklist

```bash
# pods healthy
kubectl --context <ctx> -n accounts get pods           # web + celery Running
kubectl --context <ctx> -n keycloak-customer get pods  # 2 keycloak replicas Ready

# DB host actually wired (not pending-field-export)
kubectl --context <ctx> -n accounts exec <web-pod> -- printenv DATABASE_HOST

# celery connected to the broker (no DB/redis resolution errors)
kubectl --context <ctx> -n accounts logs deploy/accounts-celery --tail=30

# login: browser to https://accounts-<env>.tail2726a2.ts.net -> Keycloak -> back
# logout: the /logout button should round-trip (see §7)
```

- **Admin panel:** `https://accounts-<env>.tail2726a2.ts.net/admin/` (Django admin),
  gated on `is_superuser` + `is_staff`. Grant via the `make_superuser` management
  command (§10) or the `is_services_admin` OIDC attribute mapped in the app middleware.

---

## 9. Temporary workarounds & prod hardening (TODO)

These keep **dev** working but must be resolved before the prod cutover (#142):

| Workaround (dev) | Why | Durable fix |
|------------------|-----|-------------|
| Keycloak `patch-login-theme` initContainer (seds `?no_esc` onto the whole login theme) | KC 26.5.7 HTML-escapes Freemarker → `&amp;` in `window._page` URLs → login/flows 400 | Merge thunderbird-accounts **PR #1030** (theme `?no_esc`), rebuild + re-mirror image, drop the initContainer |
| StatefulSet `command` override forcing `--proxy-headers xforwarded` | image `entry-keycloak.sh` hardcodes `--proxy-headers forwarded` | Make `entry-keycloak.sh` honor `KC_PROXY_HEADERS` (thunderbird-accounts image change) |
| Moving `quay.io/keycloak/keycloak:26.5` base tag | escaping behavior drifted silently between builds | Pin `Dockerfile.keycloak` to a specific `26.5.x` |
| `ALLOWED_HOSTS: "*"`, `APP_ENV` review | dev convenience | pin `ALLOWED_HOSTS` to the real host for prod |
| Live Keycloak client edits (redirect / post-logout URIs) | branch DB, done by hand | codify in realm config |
| Neon-branch dev DB | fast dev clone | prod uses the net-new ACK RDS, migrate at cutover |

---

## 10. Operational recipes

### Reset a dev user's password (Neon-branch Keycloak, no usable env admin)

The env `KC_BOOTSTRAP_ADMIN_*` isn't valid on the branch DB. Mint a throwaway admin
via `kc.sh bootstrap-admin user` (DB-direct, with cache/port overrides so it doesn't
clash with the running server), reset, then delete the throwaway admin. The new
password is generated locally and piped to the pod over **stdin** (never in args/logs):

```bash
# generate locally; write to a local 600 file; feed to the pod via stdin
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
kubectl --context <ctx> -n accounts exec deploy/accounts-web -- \
  python3 manage.py make_superuser <email>
```
