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

### Before this is deploy-ready (`REPLACE_*`)

- **`REPLACE_KARGO_PROJECT_NS`** — the Kargo Project namespace for Accounts (defined by
  the sibling Project/Warehouse/Stage spec, not yet in this repo).
- **`REPLACE_E2E_IMAGE`** — a Playwright image bundling `test/e2e` + browsers + the
  `deployment-analysis-e2e` script, built by Accounts CI
  ([thunderbird-accounts#1137](https://github.com/thunderbird/thunderbird-accounts/issues/1137)).
- **Secrets Manager** — create `mzla/tb-dev/accounts-e2e` with `ACCTS_OIDC_EMAIL` +
  `ACCTS_OIDC_PWORD` for an existing tb-dev test user; ensure the Kargo cluster has the
  `aws-secrets-manager` ClusterSecretStore + IRSA read access to that path.
