# Kargo freight verification

Kargo promotes Accounts freight (image digests) into the env branches and **verifies**
each promotion by running an [Argo Rollouts `AnalysisTemplate`](https://kargo.akuity.io/how-to-guides/working-with-stages/#verification).
This directory holds those verification specs. It is **separate** from `overlays/`
(the ArgoCD app-of-apps that deploys the app itself) — Kargo resources live in the
Kargo **Project** namespace, not the `accounts` app namespace.

```
kargo/
  tb-dev/
    analysistemplate-accounts-signin.yaml   # runs the @deployment-analysis sign-in E2E
    externalsecret-e2e-creds.yaml           # test-user creds (ESO -> accounts-e2e-creds)
    kustomization.yaml
```

## accounts-signin-e2e

Runs the `@deployment-analysis` Playwright sign-in test from
[`thunderbird-accounts` test/e2e](https://github.com/thunderbird/thunderbird-accounts/pull/1146)
(`npm run deployment-analysis-e2e`) against the just-promoted tb-dev deployment. It
exercises OIDC sign-in end to end; if sign-in breaks, the freight is not verified.

**How it runs (approach b).** A stock Playwright image
(`mcr.microsoft.com/playwright:v1.59.1-noble`, tag pinned to the repo's
`@playwright/test`) checks out `test/e2e` at run time and runs the suite directly —
`git clone` → `npm ci` → `npx playwright install firefox` → `npm run
deployment-analysis-e2e` — mirroring how Accounts CI runs it (`validate.yml`
`run-e2e-tests-local`). No bespoke E2E image to build/publish. The repo is public, so
the clone needs no credentials; `ACCTS_E2E_REF` (default `main`) selects the ref.

**Follow-up (c), noted for later.** Instead of running Playwright in-cluster, have Kargo
trigger the existing GitHub Actions E2E workflow (an `AnalysisTemplate` `web`/webhook
provider that dispatches the workflow and polls its status). That reuses CI's exact
runner setup + secrets and needs no in-cluster browser/egress. Revisit if the
in-cluster clone/install is slow or flaky, or if CI should own the run.

**`ACCTS_TARGET_ENV=dev` is deliberate.** On dev the test user has no Pro subscription
(subscribe isn't automated yet), so the suite's `dev` guard skips the subscription-
detail dashboard assertions while still exercising sign-in via the test's `beforeEach`.
With any other value the test hard-fails, because `navigateToDashboard()` requires
`/dashboard` and a subscription-less user is redirected to `/subscribe`.

Wire it into the Accounts Kargo Stage:

```yaml
spec:
  verification:
    analysisTemplates:
      - name: accounts-signin-e2e
```

### Before this is deploy-ready

- **Secrets Manager** — create `mzla/tb-dev/accounts-e2e` with `ACCTS_OIDC_EMAIL` +
  `ACCTS_OIDC_PWORD` for an existing tb-dev test user; ensure the cluster running the
  Kargo AnalysisRuns has the `aws-secrets-manager` ClusterSecretStore + IRSA read access
  to that path.
- **Stage wiring** — add the `verification.analysisTemplates` block above to the
  `tb-accounts`/`tb-dev` Stage (its `spec.verification` is currently empty).
- **Egress** — the AnalysisRun Job needs outbound access to GitHub + npm (clone/install)
  and to `accounts.tb-dev.thunderbird.dev` + `auth.tb-dev.thunderbird.dev` (the sign-in
  flow). All public hosts.

Namespace (`tb-accounts`) is now filled in; the manifests pass `kubectl apply
--dry-run=server`.
