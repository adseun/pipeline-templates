# `mobile-apps-pipeline.yml`

Builds Android (APK) and iOS (IPA) apps, runs an Appknox mobile security scan,
and optionally distributes to Azure Blob Storage / TestFlight.

**This pipeline works differently from the other six.** It is a standalone,
fully-written pipeline — not a parameterised template built from the shared
`templates/stages`/`jobs`/`steps` layers, and it has no `parameters:` block for
a calling repo to fill in. To use it, **copy the file into your app repo** and
edit it directly (scheme names, bundle paths, and app identifiers are
hardcoded for a single app). Read the whole file before adapting it — this
doc summarises what's in it, but the source is short enough to read directly.

## Stage flow

```
Build              (parallel: BuildAndroid, BuildIOS)
  → SecurityScan     (parallel: ScanAndroid, ScanIOS — Appknox; skippable via RUN_SECURITY_SCAN)
    → Distribute        (parallel: DistributeAndroid → Blob Storage, DistributeIOS → TestFlight; off by default via RUN_DISTRIBUTE)
```

Triggers on pushes to `main`, `develop`, and `release/*`; pull requests do not
trigger a run (`pr: none`).

## Prerequisites

- Variable group: `devsecops-secrets`, providing at minimum:
  `ANDROID_KEY_ALIAS`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_PASSWORD`,
  `APPLE_CERTIFICATE_SIGNING_IDENTITY`, `APPLE_PROV_PROFILE_UUID`,
  `APPKNOX_ACCESS_TOKEN`, `SLACK_WEBHOOK_URL`, `AZURE_STORAGE_ACCOUNT`,
  `AZURE_STORAGE_CONTAINER`, `IOS_BUNDLE_ID`
- Secure files (Pipelines → Library → Secure files): `release.keystore`,
  `distribution.p12`, `distribution.mobileprovision`
- Service connections: `AzureConnection` (Blob Storage upload),
  `AppleAppStoreConnection` (TestFlight upload)
- Android build requires an `android/` folder with a Gradle wrapper; iOS build
  requires an `ios/` folder with a CocoaPods `Podfile` and an
  `ios/ExportOptions.plist`

## Pipeline-level variables (edit these directly in your copy)

| Variable | Default | Notes |
|---|---|---|
| `NODE_VERSION` | `18.x` | Note this differs from the `24.x` baseline used by the Angular pipelines — align it with your app's actual toolchain, not the platform default. |
| `JAVA_VERSION` | `17` | |
| `RUN_SECURITY_SCAN` | `true` | Set to `false` to skip the Appknox stage entirely — this is currently the app's *only* security gate, so treat flipping it off as a deliberate, reviewed decision, not a quick unblock. |
| `RUN_DISTRIBUTE` | `false` | Set to `true` once you're ready to auto-publish from CI. |

Hardcoded values you'll need to change per app: the Xcode `scheme`
(`MobileApp`), `xcWorkspacePath` (`ios/MobileApp.xcworkspace`), archive/export
paths, and the Gradle wrapper version pinned in the `curl` command in the
`BuildAndroid` job.

## Known limitations for this pipeline

- Not integrated with the shared `templates/` library — fixes and
  improvements made to the other six pipelines (timeouts, SAST/DAST parity,
  naming conventions) do not automatically apply here.
- The Gradle wrapper JAR is downloaded via `curl` with no checksum
  verification. If your org requires verified supply-chain provenance for
  build tooling, vendor the wrapper jar into your app repo instead of pulling
  it at build time.
- Appknox is the only security scan in this pipeline — there's no SAST/SCA
  step comparable to the Snyk scans the other pipelines run against
  source code, only a post-build binary scan.
- No unit/instrumentation tests run before packaging the release build —
  the pipeline goes straight from `npm install` to `assembleRelease`/
  `xcodebuild`. If the app has a test suite, add a test step ahead of the
  build so a regression is caught before it reaches Appknox, not after.
- `pr: none` means pull requests get no CI validation at all (build, or
  otherwise) before merge — every other pipeline in this repo at least
  builds and SAST-scans on PRs. Consider adding a PR-triggered `Build` stage
  run (without the signing/distribute stages) so broken PRs are caught
  before merge, not after.
- Signing credentials are appended in plaintext to `android/gradle.properties`
  inside the build workspace for the Gradle build to read. Low risk as long
  as the workspace isn't archived or published as a diagnostic artifact —
  worth a one-line comment in the pipeline itself so nobody adds a
  `publish: $(Build.SourcesDirectory)` diagnostic step later without
  realizing it would leak these.
