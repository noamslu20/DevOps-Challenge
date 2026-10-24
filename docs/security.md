# Security design

This document covers section 5 of the assessment: how the pipeline handles secrets, permissions,
supply chain and production access, and which risks the design mitigates. Placeholder names only;
no real credentials exist anywhere in this repository or its settings.

## Controls implemented

| Control | Where | What it does |
|---|---|---|
| Least-privilege workflow token | every workflow: `permissions: contents: read`; `publish-release` job only: `contents: write` | The automatic `GITHUB_TOKEN` can only read the repo; the single job that creates tags and releases gets write access to contents and nothing else. No personal access tokens anywhere. |
| Actions pinned to commit SHAs | every `uses:` line | A tag like `v7` can be moved to different code; a 40-character SHA cannot. The version is kept as a comment for humans and for Dependabot. |
| Dependabot | `.github/dependabot.yml` | Weekly PRs for action SHAs, npm and NuGet packages, each tested by the normal CI before merge. |
| Lockfiles and locked restores | `frontend/package-lock.json` + `npm ci`; `backend/**/packages.lock.json` + `dotnet restore --locked-mode` | Builds are reproducible and a dependency cannot change without a committed diff. |
| Dependency vulnerability gates | `backend/Directory.Build.props` (NU1903/NU1904 as errors); `ci-frontend.yml` audit step | High and critical advisories fail the backend build because those packages ship to the server. The frontend scan is advisory, because dev-only tooling advisories must not block releases of code they never ship in. |
| No secrets in the pipeline | all workflows | The pipeline needs no secrets beyond `GITHUB_TOKEN`. Runtime secrets are provisioned on the server by operations; the deploy script only checks that the required variable names exist (`Assert-AppPoolSecretsProvisioned`) and never reads values. |
| Expressions never interpolated into scripts | all `run:` steps | Values are mapped through `env:` and read as `$VAR`; `${{ }}` inside a script is a script-injection vector. |
| Artifacts contain no environment config | `ci-backend.yml` Package step | `appsettings.Development.json` is removed before packaging; `appsettings.json` holds logging levels only. Angular receives its environment config (`config.json`, API base URL) at deploy time and it contains no secret. |
| Release authenticity | `cd-deploy.yml` validate job | Tag must match `<component>-vX.Y.Z`, the release must exist and not be a draft, its author must be the CI bot, and its commit must be an ancestor of `main`. |
| Release integrity | `Deploy-Release.ps1` via `Test-PackageChecksum` | SHA-256 of the zip is verified before extraction. |
| Protected release tags | ruleset `release-tags` on `*-v*` | Tags cannot be deleted or moved, so a published version can never silently change. |
| Protected main branch | ruleset `protect-main` | Changes reach `main` only through a pull request; force pushes and deletion are blocked. |
| Protected environments | `staging`, `production` | Production requires a reviewer and accepts deployments from `main` only. Staging deploys need no human. |
| Deployment lock | `concurrency` group `deploy-<component>-<environment>` in both CD workflows | A deploy and a rollback of the same component never overlap, and a running deploy is never cancelled midway. |
| Scoped configuration | repository and environment variables | Non-secret config lives in variables; environment-scoped values resolve per environment, so one workflow file serves staging and production without conditional logic. |
| Pipeline code ownership | `.github/CODEOWNERS` | Changes to workflows and deploy scripts are owned by the platform owner; a team enables "Require review from Code Owners" in the ruleset. |
| Build provenance not served publicly | `frontend/public/web.config` `hiddenSegments` | `manifest.json` stays on disk for operators but is not served to browsers. |

## Risks and mitigations

| # | Risk | Mitigation in this design |
|---|---|---|
| 1 | Secret leakage into logs, artifacts or deployment packages | The pipeline carries no runtime secrets, so there is nothing to leak. Any value that is passed goes through `env:` and is masked by GitHub; the adapter logs variable names, never values; artifacts are inspected to contain only build output and logging config. |
| 2 | Compromised third-party action (supply chain) | Every action is pinned to an immutable commit SHA, only first-party `actions/*` are used, Dependabot proposes updates as reviewable PRs, and the workflow token the action could abuse is read-only except in the release job. |
| 3 | Unauthorized or accidental production deployment | Deploys are manual, the `production` environment requires an approver and accepts `main` only, and the validate job rejects any release that was not created by CI from `main`. Pull-request builds can never become releases. |
| 4 | Untrusted pull-request code reaching the self-hosted runner or production secrets | CI runs on GitHub-hosted runners only. The self-hosted runner is used exclusively by the CD workflows, which are manual and gated. The repository is private, and the runner belongs to a runner group restricted to this repository. |
| 5 | Tampered artifact between build and deployment | The release is created by the CI job from the exact bytes it tested; its tag is protected; the deploy verifies the author, the commit lineage and the SHA-256 checksum before extracting anything. |
| 6 | Secrets exposed in browser code | The Angular build contains no secret and never will: the only runtime configuration it receives is a public API base URL written to `config.json` at deploy time. All secrets live in the API's app pool on the server. |

## Secrets and variables

### Secrets

None are required for this design. The self-hosted runner's Windows service account is the deployment
identity, runtime secrets are provisioned on the server, and GitHub access uses the per-job `GITHUB_TOKEN`.

Placeholder names for the variants that would need a secret:

| Name | Scope | Used by |
|---|---|---|
| `WINRM_DEPLOY_PASSWORD` | environment | Dedicated-deployment-host variant: credential for PowerShell remoting to the IIS server (with a JEA endpoint). |
| `API_CONNECTION_STRING` | environment | Optional variant for teams that treat GitHub environments as their secret store: seeded into the app pool at deploy time, masked in logs, never written to artifacts. Not used by default. |

### Repository variables (same in all environments)

| Name | Purpose |
|---|---|
| `DEPLOY_MODE` | `Mock` in this assessment; `Iis` on a real server. |
| `DEPLOY_RUNNER_LABEL` | Not set here. On a real setup: the self-hosted runner label; when unset the CD jobs run on a hosted runner in mock mode. |
| `FRONTEND_SITE_NAME`, `FRONTEND_APP_POOL` | IIS site and app pool of the Angular frontend. |
| `API_SITE_NAME`, `API_APP_POOL` | IIS site and app pool of the API. |
| `API_REQUIRED_VARIABLES` | Comma-separated names of app-pool variables operations must provision before a deploy may proceed. |
| `RELEASES_TO_KEEP` | Release folders kept on the server; active, previous and known-good are never pruned. |

### Environment variables (one value per environment)

| Name | Purpose |
|---|---|
| `ASPNETCORE_ENVIRONMENT` | Set on the API's app pool at deploy time (`Staging` / `Production`). |
| `FRONTEND_API_BASE_URL` | Written to the frontend's `config.json` at deploy time. Public value. |
| `API_HEALTH_URL`, `FRONTEND_HEALTH_URL` | Health-check endpoints used after every switch (Iis mode). |
| `DEPLOY_ROOT` | Root folder of the release layout on the server (Iis mode). |

## What a team setup adds

- An approver team instead of a single reviewer, with "Prevent self-review" enabled.
- "Require review from Code Owners" in the `protect-main` ruleset.
- A runner group that limits the self-hosted runner to this repository and to the CD workflows.
- Optionally, the dedicated deployment host variant (runner on a jump host, JEA endpoint on the IIS server).
- Optionally, build provenance attestations (`actions/attest-build-provenance` in CI, `gh attestation verify` in CD) to bind each zip cryptographically to the workflow run that produced it.
