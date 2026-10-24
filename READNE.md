# DevOps Technical Assessment: CI/CD for Angular + .NET 10 to on-premises IIS

A secure GitHub Actions pipeline for a monorepo with an Angular 22 frontend and a .NET 10 Web API.
CI builds, tests and packages each component independently and publishes versioned releases to GitHub.
CD deploys a selected release to a Windows/IIS server through a self-hosted runner, verifies health,
and rolls back automatically on failure. No real server exists for this assessment, so the deployment
engine runs in a mock mode that exercises the same code paths against a simulated IIS.

- Design and diagrams: [docs/deployment-design.md](docs/deployment-design.md)
- Security controls, risks and mitigations: [docs/security.md](docs/security.md)

## Assumptions

- Latest stable Angular at assessment time: **22.2.3** (checked with `npm view @angular/cli version` on 2026-10-21). Node 24 LTS.
- .NET SDK **10.0.x** pinned via `global.json`; the API is a minimal Web API with `/health` and `/api/version`.
- Both applications are deliberately minimal; the assessment is about the pipeline.
- Backend and frontend live in one repository with **separate CI/CD per component**, each triggered only by its own paths.
- The real target is a Windows server with IIS, reached by a self-hosted runner inside the network. In this assessment the CD workflows run on GitHub-hosted runners in **Mock mode**; the switch is a single repository variable.
- The repository is private: self-hosted runners must never be attached to public repositories.

## Repository structure

```
.github/
  workflows/
    ci-frontend.yml        PR + push to main (frontend/**): build, test, package, publish release
    ci-backend.yml         PR + push to main (backend/**):  build, test, package, publish release
    ci-deploy-scripts.yml  PR + push to main (deploy/**):   full deploy/rollback simulation
    cd-deploy.yml          manual: validate release -> approval gate -> deploy -> health -> auto-rollback
    cd-rollback.yml        manual: switch to a release already on the server -> health
  dependabot.yml           weekly updates for action SHAs, npm and NuGet
  CODEOWNERS               pipeline and deploy scripts owned by the platform owner
frontend/                  Angular 22 app, Vitest tests, VERSION, .nvmrc, public/web.config (IIS)
backend/
  Api/                     .NET 10 Web API (/health, /api/version)
  Api.Tests/               xUnit integration test against /health
  Directory.Build.props    lock files + vulnerability advisories as build errors
  VERSION
deploy/
  Deploy-Release.ps1       verify -> extract -> configure -> preflight -> switch -> health -> rollback on failure
  Rollback-Release.ps1     switch to previous (or chosen) release -> health
  Test-Health.ps1          health check (HTTP in Iis mode, file-based with failure injection in Mock mode)
  IisAdapter.psm1          the only code that talks to IIS; Mock and Iis implementations
  ReleaseManager.psm1      shared logic: layout, state file, atomic extraction, activation, prune
  Invoke-DeploySimulation.ps1  scripted lifecycle demo with assertions (also the scripts' CI)
docs/                      design, diagrams, security
global.json                .NET SDK pin
```

## How the pipeline works

1. **CI** (`ci-frontend.yml`, `ci-backend.yml`): on every pull request and push to `main` touching that
   component. Installs pinned toolchains, restores from lockfiles, tests, builds, and packages a zip with
   a `manifest.json` (component, version, commit, run id, run number, run attempt, build time) and a
   SHA-256 file. Version = `MAJOR.MINOR` from the component's `VERSION` file + the workflow run number,
   e.g. `backend-1.0.8-5e51b42.zip`. PR builds are kept as artifacts for 7 days, main builds for 30.
2. **Release** (same workflows, `publish-release` job, push to `main` only): creates the GitHub Release
   `<component>-vX.Y.Z` at the exact commit, with the zip and checksum attached. Idempotent on reruns.
   Release tags are protected against deletion and updates.
3. **CD deploy** (`cd-deploy.yml`, manual): the operator picks a component, a release tag and an
   environment. A validate job checks the tag format, that the release exists and is not a draft, that
   it was created by the CI bot, and that its commit is on `main`. The deploy job runs under the chosen
   environment (production requires an approval), downloads the release, verifies the checksum, and
   runs `Deploy-Release.ps1`. The job summary reports outcome, versions and commit.
4. **CD rollback** (`cd-rollback.yml`, manual): switches to the recorded previous release or a chosen
   version already on the server, verifies health, same approval gate.

## Running it

- **CI**: open a pull request touching `frontend/`, `backend/` or `deploy/`. Merge to `main` to publish a release.
- **Deploy**: Actions, *CD Deploy*, *Run workflow*: component, release tag (e.g. `backend-v1.0.8`),
  environment. Tick `simulate_failure` (Mock mode) to see the automatic rollback.
- **Rollback**: Actions, *CD Rollback*, *Run workflow*: component, environment, optional target version.
- **Simulation locally** (requires PowerShell 7, `dotnet tool install --global PowerShell`):
  `pwsh ./deploy/Invoke-DeploySimulation.ps1`
- **Apps locally**: `cd frontend && npm ci && npx ng test --watch=false && npx ng build`;
  `cd backend && dotnet test && dotnet publish Api/Api.csproj -c Release -o /tmp/api-publish`.

## Secrets and variables

The pipeline needs **no secrets** beyond the per-job `GITHUB_TOKEN`: the self-hosted runner's service
account is the deployment identity, and runtime secrets are provisioned on the server by operations.
The deploy only verifies that the required variable names exist. Placeholder names for the variants
that would need a secret (`WINRM_DEPLOY_PASSWORD`, `API_CONNECTION_STRING`) are described in
[docs/security.md](docs/security.md).

| Variable | Scope | Purpose |
|---|---|---|
| `DEPLOY_MODE` | repository | `Mock` here; `Iis` on a real server |
| `DEPLOY_RUNNER_LABEL` | repository | unset here (hosted runner); the self-hosted runner label in a real setup |
| `FRONTEND_SITE_NAME`, `FRONTEND_APP_POOL` | repository | IIS site and app pool of the frontend |
| `API_SITE_NAME`, `API_APP_POOL` | repository | IIS site and app pool of the API |
| `API_REQUIRED_VARIABLES` | repository | app-pool variable names that must exist before a deploy |
| `RELEASES_TO_KEEP` | repository | release folders kept on the server (active/previous/known-good never pruned) |
| `ASPNETCORE_ENVIRONMENT` | environment | `Staging` / `Production`, set on the API app pool |
| `FRONTEND_API_BASE_URL` | environment | public API URL written to the frontend's `config.json` |
| `API_HEALTH_URL`, `FRONTEND_HEALTH_URL` | environment | health endpoints (Iis mode) |
| `DEPLOY_ROOT` | environment | release layout root on the server (Iis mode) |

## Assessment coverage

| Section | Requirement | How | Status |
|---|---|---|---|
| 1 | Angular (latest stable), .NET 10 API, tests, workflows, scripts, clear structure | see structure above | implemented |
| 2 | CI on PR and push to main, separate per component, path filters | `ci-frontend.yml`, `ci-backend.yml` | implemented |
| 2 | Compatible Node and .NET SDK versions | `.nvmrc`, `global.json`, setup actions | implemented |
| 2 | Restore, build, test, fail on error, package, publish versioned artifacts | CI jobs, exit codes, upload-artifact, releases | implemented |
| 3 | Unique version / commit SHA, source commit recorded | `MAJOR.MINOR.run_number` + SHA in name, `manifest.json`, release target commit | implemented |
| 3 | Retention | artifacts 7/30 days; releases permanent; server keeps N releases | implemented |
| 3 | Deploy the CI artifact, no rebuild on the server | `gh release download` + checksum in CD | implemented |
| 4 | Deploy only from authorized source | validate job: tag, non-draft release, CI author, commit on `main`; environments accept `main` only | implemented |
| 4 | Angular to IIS static site, API via ASP.NET Core Module | `web.config` in both artifacts, adapter switch | implemented (Mock), documented (real IIS) |
| 4 | Environment config without secrets in source or artifacts | environment-scoped variables, `config.json` at deploy time, app-pool variables | implemented |
| 4 | Health check and report | `Test-Health.ps1`, job summary, exit codes | implemented (Mock), HTTP path documented |
| 4 | Secure connection path | self-hosted runner, outbound only, no credentials in GitHub | documented |
| 4 | Separate demonstrable from infrastructure-dependent | this table, `IisAdapter.psm1` Mock/Iis split | implemented |
| 5 | Security requirements, risks and mitigations | [docs/security.md](docs/security.md) | implemented |
| 6 | Preserve active release until verified, versioned directories, track active | release folders, physical path switch, `state.json` | implemented (Mock) |
| 6 | Automatic rollback on failed health check | `Deploy-Release.ps1`, demonstrated by `ci-deploy-scripts.yml` and `simulate_failure` | implemented |
| 6 | Manual rollback to a chosen release, health verified after | `Rollback-Release.ps1`, `cd-rollback.yml` | implemented |
| 6 | Protect last known-good | prune exclusion, protected tags | implemented |
| 6 | Interrupted deploy, unavailable server | staging folders, `inProgress`, timeouts | documented in design doc, partially implemented |

## Known trade-offs

- **Required status checks** are not configured on `main`: a path-filtered workflow that does not run
  never reports its check and would block unrelated PRs. A team adds a small always-running
  aggregating workflow and requires that single check.
- **Mock state persistence** between hosted-runner runs uses `actions/cache`, which can be evicted after
  a week unused. It only emulates a server that keeps its disk and is skipped on a real runner.
- **"Latest" badge** on releases is cosmetic: with two independently versioned components, CD always
  selects an explicit tag.
- **Frontend dependency audit** is advisory while the backend's is blocking; see docs/security.md.
