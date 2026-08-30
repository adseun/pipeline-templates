# `legacy-backend-to-windows-instance-pipeline.yml`

Builds a legacy .NET or Java backend, runs SAST, and deploys the published
artifact to IIS on a Windows VM per environment. No containerisation step —
this is the VM-deploy path for backends that haven't moved to OpenShift.

See [../../README.md](../../README.md) for the shared architecture, the
branch → environment convention, and prerequisites common to all pipelines.

## Stage flow

```
Build_And_Security                (build, SAST, test, publish artifact)
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
| `projectName` | string | **yes** | — | |
| `pathToProjectBuildFile` | string | no | `''` | Path to the `.csproj`/`build.gradle`/`pom.xml`, if not at repo root. |
| `environmentConfig` | object | no | see below | Each environment maps to its own like-named ADO Environment by default. |
| `buildCommand` | string | no | `'npm run build'` | Vestigial default from the frontend templates — override this for a .NET/Java build; the underlying job template drives the real build via `BuildType`, not this parameter. |
| `buildOutputPath` | string | no | `'dist'` | |
| `BuildType` | string | no | `dotnet` | One of `dotnet`, `java_gradle`, `java_maven`. |
| `poolName` | string | no | `''` | |
| `deployPath` | string | **yes** | — | Target path on the Windows VM / IIS site. |
| `qualysWebAppName` | string | **yes** | — | |
| `port` | number | **yes** | — | |
| `customSubFolderForArtifiact` | string | no | `''` | Sub-folder within the published artifact to deploy (spelled exactly this way in the template). |
| `customDestinationFolder` | string | no | `''` | |
| `qaRepoName` | string | no | `Plain_QA_Automation_Repo` | |
| `qaAzureProject` | string | no | `DevSecOps Transformation` | |

**Default `environmentConfig`:**

```yaml
dev:        { environmentName: dev,        poolName: AgentPool-DEV_UAT }
uat:        { environmentName: uat,        poolName: AgentPool-DEV_UAT }
pilot:      { environmentName: pilot,      poolName: AgentPool-DEV_UAT }
production: { environmentName: production, poolName: AgentPool-DEV_UAT }
dr:         { environmentName: dr,         poolName: AgentPool-DEV_UAT }
```

## Minimal example

```yaml
resources:
  repositories:
    - repository: templates
      type: git
      name: <your-project>/pipeline-templateS
      ref: main

extends:
  template: pipelines/legacy-backend-to-windows-instance-pipeline.yml@templates
  parameters:
    projectName: my-legacy-service
    BuildType: dotnet
    deployPath: 'C:\inetpub\wwwroot\my-legacy-service'
    port: 8081
    qualysWebAppName: 'my-legacy-service (DevSecOps)'
    environmentConfig:
      dev:        { environmentName: dev,        approvalRequired: false, approvalTimeout: 3600 }
      uat:        { environmentName: uat,        approvalRequired: true,  approvalTimeout: 3600 }
      pilot:      { environmentName: pilot,      approvalRequired: true,  approvalTimeout: 3600 }
      production: { environmentName: production, approvalRequired: true,  approvalTimeout: 3600 }
      dr:         { environmentName: dr,         approvalRequired: true,  approvalTimeout: 3600 }
```