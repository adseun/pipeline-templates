# `angular-to-windows-instance-pipeline.yml`

Builds an Angular/frontend app, runs SAST, and deploys it to IIS on a Windows
VM per environment. IIS is the only frontend deploy target; the Ubuntu/nginx
variant has been retired.

See [../../README.md](../../README.md) for the shared architecture, the
branch → environment convention, and prerequisites common to all pipelines.

## Stage flow

```
Build_And_Security                (build, SAST, publish artifact)
  → Deploy_<env>                    (one per environment in deployToEnvironments, in order)
      → DAST_dev + QA_Test            (hotfix branches only, once, after the dev deploy)
  → DAST_<branch env> + QA_Test     (non-hotfix branches only)
  → Deploy_dr                       (production branch only, after all of the above)
```

## Prerequisites

- Service connection: `ARM-ServiceConnection`
- ADO Environments: `dev`, `uat`, `pilot`, `production`, `dr`
- Variable group providing `BROWSERSTACK_USERNAME` / `BROWSERSTACK_ACCESS_KEY` for the QA stage

## Parameters

| Name | Type | Required | Default | Notes |
|---|---|---|---|---|
| `projectName` | string | **yes** | — | Used for artifact naming and default deploy path resolution. |
| `environmentConfig` | object | no | dev/uat/pilot/production/dr | Override to change agent pools or approval behaviour. |
| `useKeyVault` | boolean | no | `false` | Pull build-time secrets from Key Vault instead of pipeline variables. |
| `buildCommand` | string | no | `''` (falls back to `environmentConfig[<env>].buildCommand`) | Explicit override wins over the per-environment default. |
| `buildOutputPath` | string | no | `'dist'` | Path to the built app, relative to repo root. |
| `BuildType` | string | no | `'none'` | Passed through to the SAST step. |
| `poolName` | string | no | `''` | Empty string uses the template's default Microsoft-hosted pool. |
| `deployPath` | string | **yes** | — | Target path on the Windows VM / IIS site to deploy into. |
| `qualysWebAppName` | string | **yes** | — | Qualys WAS application name for DAST. |
| `port` | number | **yes** | — | Port the IIS site binds to. |
| `customSubFolderForArtifact` | string | no | `''` | Sub-folder within the published artifact to deploy (e.g. the `browser/` folder Angular 17+ builds produce), renamed/flattened into `customDestinationFolder` at deploy time. |
| `customDestinationFolder` | string | no | `''` | Sub-folder under `deployPath` to copy into. |
| `qaRepoName` | string | no | `Plain_QA_Automation_Repo` | BrowserStack QA automation repo. |
| `qaAzureProject` | string | no | `DevSecOps Transformation` | ADO project containing the QA repo. |

## Minimal example

```yaml
resources:
  repositories:
    - repository: templates
      type: git
      name: <your-project>/pipeline-templateS
      ref: main

extends:
  template: pipelines/angular-to-windows-instance-pipeline.yml@templates
  parameters:
    projectName: my-frontend-app
    deployPath: 'C:\inetpub\wwwroot\my-frontend-app'
    port: 8080
    qualysWebAppName: 'my-frontend-app (DevSecOps)'
```

## Known limitations for this pipeline
