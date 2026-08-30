# `backend-to-openshift-with-oc-cli-pipeline.yml`

Builds a containerised backend, scans and promotes the image through each
environment's ACR, then deploys to OpenShift by logging in with the `oc` CLI
directly (no GitOps repo involved). This is the only OpenShift pipeline in the
library; the ArgoCD/GitOps variant has been retired.

> **Rollback stage is wired in** 

See [../../README.md](../../README.md) for the shared architecture, the
branch → environment convention, and prerequisites common to all pipelines.

## Stage flow

```
Build_And_Security          (build, SAST, test, publish artifact)
  → Build_Container_Image     (dev / hotfix branches only — build & push image to ACR)
  → Scan_Sign_Container_Image   (RHACS scan; signs the image if deploying to dev)
  → Promote_Container_Image     (promote image to the target environment's ACR)
  → Deploy_<env>                 (one per environment in deployToEnvironments, via oc CLI, in order)
      → DAST_dev + QA_Test          (hotfix branches only, once, after the dev deploy)
  → DAST_<branch env> + QA_Test   (non-hotfix branches only)
  → Deploy_dr                     (production branch only, after all of the above)
```

## Prerequisites

- Service connection: `ARM-ServiceConnection`
- Variable groups: `build-nonprod-vars`, `build-prod-vars`, `build-uat-vars`,
  `build-dev-vars`, `build-pilot-vars`, `build-hotfix-vars`, `deployment-metadata`,
  `ocp-nonprod-vars` (provides `OCPNONPRODSERVER`/`OCPNONPRODTOKEN`, used for
  `dev` and `uat`), `ocp-prod-vars` (provides `OCPPRODSERVER`/`OCPPRODTOKEN`
  and `OCPDRSERVER`/`OCPDRTOKEN`, used for `pilot`, `production`, and `dr`)
- ADO Environments: `dev`, `uat`, `pilot`, `production`, `dr`
- A `k8s/` directory (path configurable) in your app repo containing the
  Deployment/Service/Route manifests the deploy step will apply — see
  [`examples/k8s-deployment.yaml`](../../examples/k8s-deployment.yaml) for a
  starting point.

## Parameters

| Name | Type | Required | Default | Notes |
|---|---|---|---|---|
| `imageName` | string | **yes** | — | Container image name. |
| `imageVersion` | string | no | `latest` | Overridden at runtime by the immutable build/promoted tag in most stages. |
| `dockerFilePath` | string | no | `$(Build.SourcesDirectory)/Dockerfile` | |
| `projectName` | string | **yes** | — | |
| `pathToProjectBuildFile` | string | no | `''` | Path to the `.csproj`/`build.gradle`/`pom.xml`, if not at repo root. |
| `environmentConfig` | object | no | dev/uat/pilot/production/dr, see below | |
| `BuildType` | string | no | `dotnet` | One of `dotnet`, `java_gradle`, `java_maven`. |
| `qualysWebAppName` | string | **yes** | — | |
| `buildConfiguration` | string | no | `Release` | .NET builds only. |
| `dotnetVersion` | string | no | `8.0.x` | .NET builds only. |
| `testProjectPath` | string | no | `tests/**/*.csproj` | .NET builds only. |
| `javaVersion` | string | no | `17` | Java builds only. |
| `mavenGoals` | string | no | `test` | Maven builds only. |
| `ocpNamespace` | string | no | `''` | **Set this** — the deploy step needs a real namespace. |
| `k8sDirectory` | string | no | `templates/k8s` | Path (in your app repo) to the manifests to apply. |
| `qaRepoName` | string | no | `Plain_QA_Automation_Repo` | |
| `qaAzureProject` | string | no | `DevSecOps Transformation` | |

**Default `environmentConfig`:** the same five environments (`dev`, `uat`,
`pilot`, `production`, `dr`) used across the library — see
[angular-to-windows-instance-pipeline.md](angular-to-windows-instance-pipeline.md#parameters)
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
  template: pipelines/backend-to-openshift-with-oc-cli-pipeline.yml@templates
  parameters:
    imageName: my-backend-service
    projectName: my-backend-service
    BuildType: dotnet
    ocpNamespace: my-team-dev
    qualysWebAppName: 'my-backend-service (DevSecOps)'
```

