# `legacy-services-or-cronjobs-to-windows-instance.yml`

Builds a legacy .NET or Java app and deploys it as a **Windows Service** or a
**scheduled Task Scheduler job** on a Windows VM, rather than an IIS site.
Same build/SAST stage as
[legacy-backend-to-windows-instance-pipeline.yml](legacy-backend-to-windows-instance-pipeline.md),
with service/cron-specific deployment parameters.

See [../../README.md](../../README.md) for the shared architecture, the
branch → environment convention, and prerequisites common to all pipelines.

## Stage flow

```
Build_And_Security                (build, SAST, test, publish artifact)
  → Deploy_<env>                    (one per environment in deployToEnvironments, in order)
      → DAST_dev + QA_Test            (hotfix branches only, once, after the dev deploy)
  → Deploy_dr                       (production branch only, after all of the above)
```

Note the difference from its IIS sibling: **there is no standalone DAST/QA
stage for non-hotfix branches** in this pipeline — background services and
cron jobs typically have no HTTP surface for Qualys DAST to scan. If your job
does expose an HTTP endpoint worth scanning, ask the platform team whether
you should be on the IIS pipeline instead.

## Prerequisites

- Service connection: `ARM-ServiceConnection`
- ADO Environments: `dev`, `uat`, `pilot`, `production`, `dr`
- Variable group providing `BROWSERSTACK_USERNAME` / `BROWSERSTACK_ACCESS_KEY` (only exercised on hotfix branches, via the QA stage)

## Parameters

| Name | Type | Required | Default | Notes |
|---|---|---|---|---|
| `projectName` | string | **yes** | — | |
| `pathToProjectBuildFile` | string | no | `''` | |
| `environmentConfig` | object | no | see below | Each environment maps to its own like-named ADO Environment by default. |
| `buildCommand` | string | no | `'npm run build'` | Vestigial default; has no effect on the actual .NET/Java build (driven by `BuildType`). |
| `buildOutputPath` | string | no | `'dist'` | |
| `BuildType` | string | no | `dotnet` | One of `dotnet`, `java_gradle`, `java_maven`. |
| `poolName` | string | no | `''` | |
| `deployPath` | string | **yes** | — | Install path on the Windows VM. |
| `qualysWebAppName` | string | **yes** | — | Only used on hotfix branches (see stage flow above). |
| `port` | number | no | — | Not required unless your service listens on one. |
| `customSubFolderForArtifiact` | string | no | `''` | Sub-folder within the published artifact to deploy. |
| `customDestinationFolder` | string | no | `''` | |
| `binaryPath` | string | **yes** | — | Path (relative to the deployed artifact) to the executable the service/task runs. |
| `cronSchedule` | string | no | `'09:00'` | 24-hour time; only relevant when deploying as a scheduled task rather than a long-running service. |
| `runAsUser` | string | no | `'NT AUTHORITY\SYSTEM'` | Execution context for the service/task. |
| `qaRepoName` | string | no | `Plain_QA_Automation_Repo` | |
| `qaAzureProject` | string | no | `DevSecOps Transformation` | |

**Default `environmentConfig`:** identical shape to the IIS legacy-backend
pipeline — each environment maps to its own like-named ADO Environment. See
[legacy-backend-to-windows-instance-pipeline.md](legacy-backend-to-windows-instance-pipeline.md#parameters)
for the full block.

## Minimal example

```yaml
resources:
  repositories:
    - repository: templates
      type: git
      name: <your-project>/pipeline-templateS
      ref: main

extends:
  template: pipelines/legacy-services-or-cronjobs-to-windows-instance.yml@templates
  parameters:
    projectName: my-nightly-job
    BuildType: dotnet
    deployPath: 'C:\services\my-nightly-job'
    binaryPath: 'my-nightly-job.exe'
    cronSchedule: '02:00'
    qualysWebAppName: 'my-nightly-job (DevSecOps)'
    environmentConfig:
      dev:        { environmentName: dev,        approvalRequired: false, approvalTimeout: 3600 }
      uat:        { environmentName: uat,        approvalRequired: true,  approvalTimeout: 3600 }
      pilot:      { environmentName: pilot,      approvalRequired: true,  approvalTimeout: 3600 }
      production: { environmentName: production, approvalRequired: true,  approvalTimeout: 3600 }
      dr:         { environmentName: dr,         approvalRequired: true,  approvalTimeout: 3600 }
```

## Known limitations for this pipeline
