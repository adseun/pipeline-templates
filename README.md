# Centralised Pipeline Templates

Shared Azure DevOps YAML pipeline templates for building, scanning, testing, and
deploying applications across the estate — Angular/React frontends, backend
services (containerised on OpenShift, or classic VM/Windows), legacy Windows
services and cron jobs, and mobile apps.

Application repositories consume these templates rather than authoring pipeline
logic from scratch. This README explains the moving parts and how to onboard a
repo; each pipeline has a full parameter reference under [`docs/pipelines/`](docs/pipelines).

## Which pipeline do I use?

| Your app is a... | Deploys to... | Use | Reference |
|---|---|---|---|
| Angular / frontend app | Windows VM (IIS) | `angular-to-windows-instance-pipeline.yml` | [docs](docs/pipelines/angular-to-windows-instance-pipeline.md) |
| Backend service (container) | OpenShift, via `oc` CLI | `backend-to-openshift-with-oc-cli-pipeline.yml` | [docs](docs/pipelines/backend-to-openshift-with-oc-cli-pipeline.md) |
| Legacy .NET/Java backend | Windows VM (IIS) | `legacy-backend-to-windows-instance-pipeline.yml` | [docs](docs/pipelines/legacy-backend-to-windows-instance-pipeline.md) |
| Windows service or scheduled job | Windows VM (service / Task Scheduler) | `legacy-services-or-cronjobs-to-windows-instance.yml` | [docs](docs/pipelines/legacy-services-or-cronjobs-to-windows-instance.md) |
| iOS / Android app | App Store / Play distribution | `mobile-apps-pipeline.yml` | [docs](docs/pipelines/mobile-apps-pipeline.md) |

If nothing here fits, talk to the platform team before writing a one-off pipeline —
the goal is that every production app in the org runs through one of these.

## Architecture

Every pipeline except `mobile-apps-pipeline.yml` is built from four layers, each
a separate, independently reusable template:

```
pipeline            (pipelines/*.yml)
  → stage            (templates/stages/*.yml)
    → job             (templates/jobs/*.yml)
      → steps           (templates/steps/*.yml)
```

- **Pipeline** — the entry point your app repo actually calls (via `extends:` or
  a `template:` reference in its own `azure-pipelines.yml`). Declares the
  parameters a consuming team fills in, and wires stages together in order.
- **Stage** — a phase of the pipeline (build, deploy, scan). `dynamic-stage.yml`
  is the generic wrapper used for most stages; `deploy-openshift-stage.yml` and
  `deploy-to-instance-stage.yml` add target-specific deployment concerns
  (ADO Environment binding, approval gates).
- **Job** — one unit of work on one agent (e.g. `build-scan-publish-backend.yml`,
  `deploy-to-openshift-using-oc-cli.yml`). Selects the agent pool and composes steps.
- **Step** — the actual task list, grouped by role under `templates/steps/`
  (e.g. `security/sast-snyk.yml`, `package/docker-build-push.yml`, `deploy/iis.yml`).

`mobile-apps-pipeline.yml` is the one exception — it's a **standalone starting
pipeline**, not a parameterised template. See its
[reference](docs/pipelines/mobile-apps-pipeline.md) for what that means in practice.

### The environment / branch convention

The non-mobile pipelines share one convention: **branch name selects target
environment**.

| Branch | Environment | Notes |
|---|---|---|
| `dev` | `dev` | No approval gate |
| `uat` | `uat` | Approval gate |
| `pilot` | `pilot` | Approval gate |
| `production` | `production` | Approval gate; also triggers a follow-up deploy to `dr` |
| `hotfix/*` | `dev` → `uat` → `pilot` → `production`, in order | Runs DAST + QA once, after the `dev` deploy, instead of once per environment |

Each environment is backed by its own Azure Container Registry credentials and
its own ADO Environment resource (`dev`, `uat`, `pilot`, `production`, `dr`),
which is what gives you the built-in approval/audit trail in the Azure DevOps
UI. Container-based pipelines promote the same image forward through each
registry rather than rebuilding per environment.

### Hotfix workflow

The industry-standard solution for shipping an urgent fix without bypassing
your normal quality gates is the **Hotfix Branch pattern** — a direct
application of the "build once, promote many" principle. It has three steps:

1. **Branch from production.** Create a `hotfix/*` branch from your production
   (or `main`) branch, not from `dev`. This ensures you're working on a
   stable, production-representative codebase rather than whatever is
   currently mid-flight in `dev`.
2. **Build and promote.** The CI/CD pipeline builds a single new
   artifact/image from that branch and promotes that same build through the
   standard promotion chain (`dev` → `uat` → `pilot` → `production`). This is
   the critical step: a hotfix does **not** get its own bespoke deployment
   process. It reuses the existing, trusted promotion pipeline to validate
   the exact same build at each stage, so a hotfix is never less-tested than
   a normal release — it's just faster because it skips the queue, not
   because it skips the gates.
3. **Merge back.** Once the hotfix has been deployed to production, merge the
   `hotfix/*` branch back into both production and `dev`
   (resolving conflicts carefully). Skipping this step is the most common
   cause of a "fixed" bug reappearing in the next normal release, because the
   fix only ever existed on the hotfix branch.

**How this maps to these templates today:** step 2 is what
`Build.SourceBranch` starting with `refs/heads/hotfix/` triggers in every
non-mobile pipeline — `deployToEnvironments` is set to
`'dev,uat,pilot,production'` so the pipeline walks the same `Deploy_<env>`
stages, backed by the same per-environment ACR/registry promotion and the
same ADO Environment approval checks, that a normal `dev`/`uat`/`pilot`/`production`
branch run would use. Nothing about the deploy path itself is special-cased
for hotfixes — only the branch pattern and the fact that all four
environments run in one pipeline execution instead of one each.

Steps 1 and 3 (branching from production, and merging the hotfix branch back
into production and `dev` afterwards) are **git hygiene the pipeline
cannot enforce for you** — there's no branch-policy check in these templates
that verifies a `hotfix/*` branch actually forked from production, or that it
was merged back afterwards. Treat both as required team process, not
optional cleanup, and consider adding a branch-policy rule or PR checklist
item for the merge-back step so it doesn't get missed under incident pressure.


### SAST / DAST / dependency scanning

SAST and SCA run via Snyk on every build (`templates/steps/security/sast-snyk.yml`),
and are not selectable per call — the estate standardises on Snyk. DAST runs
post-deploy via Qualys.

## Prerequisites

Before wiring your app repo to one of these pipelines, get the platform team to
provision (or confirm you already have access to) the following in your Azure
DevOps project:

**Service connections**
- `ARM-ServiceConnection` — used by every VM/container pipeline for
  environment-scoped Azure operations.
- `Test_Snyk2`, `Test_Qualys` — scanning tool connections
  (naming will differ per project; confirm the live names with the platform team).
- `AzureConnection`, `AppleAppStoreConnection` — mobile pipeline only.

**Variable groups** (exact set depends on which pipeline you use — see its doc)
- `build-dev-vars`, `build-uat-vars`, `build-pilot-vars`, `build-prod-vars`,
  `build-hotfix-vars`, `build-nonprod-vars` — per-environment ACR credentials,
  BrowserStack credentials, signing key metadata.
- `deployment-metadata` — image-tag/rollback bookkeeping (OpenShift pipeline).
- `ocp-nonprod-vars`, `ocp-prod-vars` — OpenShift cluster tokens (OpenShift pipeline only).
- `devsecops-secrets` — mobile pipeline only.

**ADO Environments**
- `dev`, `uat`, `pilot`, `production`, `dr` — created once per project, with
  approval checks configured per your team's policy. Deploy stages bind to
  these by name, so they must exist and be named exactly this before your
  first deploy stage will run.

**Repository setup**
- Your app repo's `azure-pipelines.yml` references the chosen template with a
  `resources.repositories` entry pointing at this templates repo, then an
  `extends:`/`template:` block passing your project's parameters. See the
  per-pipeline doc for a copy-pasteable example.

## Known limitations

Documenting these here so they're expected, not discovered mid-incident. Track
fixes with the platform team; this list should shrink over time, not grow.
Per-pipeline specifics live in each pipeline's own doc under
[`docs/pipelines/`](docs/pipelines) — this section covers defects confirmed
in the templates as of 2026-07-20.


## Getting help

Open an issue in this repo or reach out to the platform/DevSecOps team for:
onboarding a new app, requesting a new service connection or variable group,
or reporting a pipeline defect (please include the pipeline name, branch, and
a link to the failed run).
