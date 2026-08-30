# Structural refactor — what changed

Validated with `python3 tools/validate-templates.py` (PASS: 0 syntax errors,
135/135 template references resolve, shim parity OK, 0 dead doc links).

No behaviour was changed except where explicitly noted under "Behaviour changes".

## Deleted (dead code)

| File | Was | Now |
|---|---|---|
| `templates/jobs/promote-container-image.yml` | 229 lines | 45 |
| `templates/steps/rollback/openshift-argocd.yml` | 381 | 235 |
| `templates/steps/build/dotnet.yml` | 184 | 117 |
| `templates/steps/capture-variables.yml` | 3 lines, no `steps:` block | **deleted**, plus its broken reference in `composite/backend.yml` |

## Merged

| Merged into | From |
|---|---|
| `templates/stages/deploy-to-instance-stage.yml` | `deploy-ubuntu-instance-stage.yml`, `deploy-windows-instance-stage.yml`, `deploy-cronjob-window-services-to-instance-stage.yml` |
| `templates/jobs/rollback-instance-deployment.yml` | `rollback-nginx-deployment.yml`, `rollback-iis-deployment.yml`, `rollback-cronjob-windowsservice-deployment.yml` |
| `pipelines/angular-to-instance-pipeline.yml` | `angular-to-ubuntu-instance-pipeline.yml`, `angular-to-windows-instance-pipeline.yml` |

All 12 stage call sites and 8 rollback call sites were rewritten to pass
`platform:` / `targetPlatform:`.

The old Angular pipeline filenames remain as 27-line **deprecation shims** that
`extends` the merged pipeline with `targetPlatform` preset and forward all 18
parameters. Existing consumer repos need no edits. Delete the shims once every
consumer has migrated.

## Moved

- `templates/steps/*` (flat, 26 files, 5 naming conventions) →
  `build/ security/ package/ deploy/ rollback/ test/ composite/`, with the
  redundant `-steps-to-` / `-steps-for-` infixes dropped.
- `templates/k8s/deployment.yaml` → `examples/k8s-deployment.yaml`. It is a
  reference manifest consumer repos copy, not a template the pipelines consume.
  The doc link was updated.

## Added

- `tools/validate-templates.py` + `tools/README.md`. Run as a PR gate.

## Behaviour changes (need review)

Only one, in the Angular merge. The two pipelines had drifted and **the Windows
copy was ahead** — it carried three fixes the Ubuntu copy never received. The
merged pipeline is built from the Windows base, so Ubuntu consumers now get:

1. **Hotfix build-command selection.** Ubuntu indexed `environmentConfig` with
   the raw branch name, which is null on a `hotfix/*` branch.
2. **Redundant `isHotFix` check removed** from the dev DAST/QA guard.
3. **Stray backslash fixed.** Ubuntu line 192 read `port: ${{ parameters.port }}\`.

`deployPath` and `backupRoot` now have **no defaults** on the merged pipeline —
one value cannot serve both `/var/www/...` and `D:\Applications\...`. The shims
supply the correct per-platform defaults, so existing consumers are unaffected.

## Not done — needs a decision

**`templates/jobs/build-publish-legacy-cronjobs-or-window-services.yml` is
unreachable**, and so is the `composite/legacy-worker.yml` it calls.

`legacy-services-or-cronjobs-to-windows-instance.yml` builds via
`build-scan-publish-legacy-backend.yml` → `composite/legacy-backend.yml` instead.
So the cronjob/Windows-service pipeline is building through the legacy *web
backend* path, and its purpose-built worker path has never been wired up.

That looks like a miswiring rather than intentional dead code, so I left both
files in place. If the worker path is correct, change line 164 of that pipeline
to `jobTemplate: ../jobs/build-publish-legacy-cronjobs-or-window-services.yml`.
If not, both files can be deleted.

## Still outstanding from the structure review

- Folding the five pass-through job wrappers (`dast-scan`, `qa-test`,
  `promote-container-image`, `scan-and-sign-containerised-image`,
  `build-push-container-image`) into `dynamic-stage.yml`. Left alone because it
  changes `dynamic-stage.yml` for every caller, including the OpenShift
  pipelines — worth doing as its own change.
- The `Rollback_*` hotfix dependency inversion (§1.1 of the correctness review).
  Now fixable in one place — `deploy-to-instance-stage.yml` — instead of three.
  Deliberately left as a separate commit since it is behavioural.

---

# Fortify / SonarQube removal

The estate standardises on Snyk, so both alternative SAST paths are gone.

## Deleted

- `templates/steps/security/sast-fortify.yml`
- `templates/steps/security/sast-sonarqube.yml`

## Simplified

The `sastTool` switch and the `sastParameters` object existed only to choose
between the three vendors. With one vendor there is nothing to choose, so both
are gone and the composites call Snyk unconditionally:

```yaml
# before — in each of the 4 composite templates
- ${{ if eq(parameters.sastTool, 'sonarqube') }}: ...
- ${{ if eq(parameters.sastTool, 'fortify') }}:   ...
- ${{ if eq(parameters.sastTool, 'snyk') }}:
    - template: ../security/sast-snyk.yml
      parameters: ${{ parameters.sastParameters }}

# after
- template: ../security/sast-snyk.yml
  parameters:
    BuildType: ${{ parameters.BuildType }}
```

Every caller was already passing `sastTool: 'snyk'` with a `sastParameters`
object containing only `BuildType`, so the object was replaced by a plain
`BuildType` string parameter throughout the pipeline → job → steps chain.

Touched: 4 composite step templates, 4 build job templates, 6 pipelines.

## Docs

Fod* parameter rows and example lines removed from all six pipeline docs.
README rewritten: SAST is no longer described as selectable per call, and
`Test_Fortify` is dropped from the required service connections.

## ⚠️ BREAKING for consumer repos

`FodReleaseId` was a **required** parameter on every non-mobile pipeline
(marked `# Must specify`, no default) and the documented examples passed it.
It no longer exists, and Azure DevOps errors on an undeclared parameter — so
any consumer repo still passing it will fail at compile time with
`Unexpected parameter 'FodReleaseId'`.

Removed per pipeline: 2 (`angular-*`), 3 (`backend-*`, `legacy-*`).

Find affected repos before merging:

```bash
# across your ADO project
grep -rln "FodReleaseId\|FodReleaseName\|FodConnection" --include=azure-pipelines.yml .
```

The fix in each is to delete those lines — nothing replaces them.

If you would rather not coordinate that, the alternative is to re-add them to
each pipeline as optional no-ops for one release:

```yaml
  # DEPRECATED — ignored since the move to Snyk-only. Remove from your repo.
  - name: FodReleaseId
    type: string
    default: ''
```

I did not do this, because you asked for the removal and the parameter was
already inert (the Fortify path had been commented out at every call site).
It is a one-line-per-pipeline change if you want the softer landing.

## Service connection

`Test_Fortify` is no longer referenced by anything. It can be deleted from the
ADO project once no other pipelines outside this repo use it.

---

# ArgoCD and Linux deploy-target removal

## FodReleaseId

Already removed in the previous change — zero references remain in any `.yml`
or pipeline doc. The mentions in this file are the record of that removal.

## ArgoCD / GitOps — removed

`oc` CLI is now the only OpenShift deploy path.

Deleted:
- `pipelines/backend-to-openshift-with-argocd-pipeline.yml`
- `docs/pipelines/backend-to-openshift-with-argocd-pipeline.md`
- `templates/jobs/deploy-to-openshift-using-argocd.yml`
- `templates/jobs/rollback-openshift.yml`
- `templates/steps/deploy/openshift-argocd.yml`
- `templates/steps/rollback/openshift-argocd.yml`

`templates/stages/deploy-openshift-stage.yml` is **kept** — the `oc` pipeline
uses it too.

Now unused, safe to retire outside this repo once nothing else needs them:
- the `argocd` GitOps repo resource (`DevSecOps Transformation/argocd`)
- the `ARGOCD_AUTH_TOKEN` variable
- any ArgoCD Application definitions pointing at `argocd-overlays/*`

## Linux deploy target — removed

Ubuntu/nginx is no longer a deploy target.

Deleted:
- `templates/jobs/deploy-to-ubuntu.yml`
- `templates/steps/deploy/nginx.yml`
- `templates/steps/rollback/nginx.yml`
- `pipelines/angular-to-ubuntu-instance-pipeline.yml`
- `docs/pipelines/angular-to-ubuntu-instance-pipeline.md`

`platform` on `deploy-to-instance-stage.yml` and `rollback-instance-deployment.yml`
now accepts `windows` and `windows-worker` only.

### Linux *agents* were deliberately kept

`vmImage: 'ubuntu-latest'` still appears in 10 job templates — container build,
image promotion, RHACS scan/sign, OpenShift deploy and rollback, DAST, QA, and
the backend/frontend build jobs. Those are **build agents**, not deploy targets.
Removing them would break the OpenShift pipeline and every container build.
"No Linux deployments" and "no Linux agents" are different statements; only the
first was applied.

## Consequence: the Angular merge is unwound

The earlier refactor merged the two Angular pipelines into
`angular-to-instance-pipeline.yml` behind a `targetPlatform` switch. With Ubuntu
gone that switch had one value left, so the merge no longer justified itself.

`angular-to-windows-instance-pipeline.yml` is a real pipeline again (not a shim),
`angular-to-instance-pipeline.yml` and the Ubuntu shim are deleted. It keeps the
three fixes that had only ever existed on the Windows side.

**Consumer impact: none.** Repos already point at
`angular-to-windows-instance-pipeline.yml`, which still exists and takes the same
parameters. Repos pointing at the Ubuntu pipeline have no target — but they had
no deploy target either.

## Docs

- README pipeline table: Ubuntu and ArgoCD rows removed.
- README architecture section: stage/job examples updated to surviving files.
- oc-CLI doc: cross-references to the retired ArgoCD doc rewritten.
- Angular Windows doc: "Identical shape to the Ubuntu variant" rewritten.
- Prerequisites: `deployment-metadata`, `ocp-*-vars` rescoped to the one
  OpenShift pipeline.

## Validator

Shim-parity check replaced with an **orphan check** — deletions of this size can
strand templates nothing calls. It reports rather than fails, because an orphan
is sometimes a miswiring worth investigating.

Current run: 41 YAML files, 0 syntax errors, 94/94 references resolve, 0 dead
doc links, 1 orphan (the pre-existing
`build-publish-legacy-cronjobs-or-window-services.yml` miswiring documented
above — still unresolved and still needing your decision).

## Totals

| | Original | Now |
|---|---|---|
| Files | 65 | 50 |
| YAML lines | 8,417 | 5,493 |
