# accounts-deploy

Kustomize manifests for **Thunderbird Pro Accounts** — the `thunderbird-accounts`
Django app + Celery worker — deployed to the Thunderbird Pro EKS clusters
(`mzla-eks-tb-dev01`, `mzla-eks-tb-prod01`, eu-central-1, arm64/Graviton) via
ArgoCD. Epic:
[platform-infrastructure#144](https://github.com/thunderbird/platform-infrastructure/issues/144).

> **Initial scaffold.** Several values are `REPLACE_*` sentinels filled in by the
> sibling sub-issues: the multi-arch image + ECR
> ([#593](https://github.com/thunderbird/platform-infrastructure/issues/593)),
> the pod security groups
> ([#596](https://github.com/thunderbird/platform-infrastructure/issues/596)),
> the data-store hosts
> ([#597](https://github.com/thunderbird/platform-infrastructure/issues/597)),
> the secret bundle
> ([#598](https://github.com/thunderbird/platform-infrastructure/issues/598)),
> and the OIDC endpoints
> ([#599](https://github.com/thunderbird/platform-infrastructure/issues/599)).
> The `kustomize build` CI gate passes today; the manifests become deploy-ready
> as those land.

## Layout

```
bases/
  accounts/   namespace, ConfigMap (non-secret env), web Deployment (Django/Uvicorn :8087),
              celery Deployment (worker + embedded beat, single replica), Service,
              PDB, ExternalSecret (secret bundle via ESO)
overlays/
  tb-dev/     tailnet-only (Tailscale Ingress); 1 web replica; mzla/tb-dev/* secrets
  tb-prod/    tailnet-only validation (Tailscale Ingress); 2 web replicas; mzla/tb-prod/* secrets
              (public accounts.tb.pro via Cloudflare tunnel lands at cutover, #147)
```

The ArgoCD app-of-apps for each cluster lives in `platform-infrastructure`
(`argocd/tb-{dev,prod}/apps/accounts.yaml`) and points at `overlays/<cluster>`.
The cluster's Pulumi stack (`mzla-tb-{dev,prod}`) provides the Accounts **pod SG +
IRSA**; the pod SG is assigned to the pods via the overlay's `SecurityGroupPolicy`.

## Design notes

- **Migrations** run on web-pod startup (the default `scripts/entry.sh` path runs
  `manage.py migrate` + Paddle sync, then Uvicorn), mirroring ECS. dev runs a
  single web replica to avoid concurrent migrate; a dedicated migration Job is a
  planned follow-up.
- **Celery** embeds beat (`--beat`), so it stays a **single replica** to avoid
  double-firing scheduled tasks.
- **Config vs secrets**: non-secret env is in the `accounts-config` ConfigMap
  (`envFrom: configMapRef`); secrets sync from AWS Secrets Manager via the
  `accounts-secrets` ExternalSecret (`envFrom: secretRef`).
- **Health**: `GET /health` deep-checks the Keycloak admin API + dependencies, so
  it is the **readiness** gate only; liveness/startup use a lightweight TCP check.

## Build / validate

```bash
./util/kustomize-build-all.sh          # builds every overlay (CI gate)
kustomize build overlays/tb-dev        # or a single overlay
```
