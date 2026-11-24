# v0.4 release handoff

## Website and Firebase

Live app: https://meethalfway-2026-e43ca6.web.app/

Auth (anonymous and email/password), Firestore rules/indexes, Remote Config and
Hosting are deployed to `meethalfway-2026-e43ca6`. Hosting serves the Flutter
release and versioned offline worker. Public release metadata is at
`/downloads/release.json`; Android App Links use `/.well-known/assetlinks.json`.
The signing fingerprint was registered with the existing Android Firebase app.

Redeploy after a web build:

```sh
npm run build
npm run package:android  # after building the signed Android packages
npx firebase-tools@latest deploy --only hosting,firestore,auth,remoteconfig --project meethalfway-2026-e43ca6
```

Do not deploy `functions` as part of the free deployment. Billing is disabled;
the optional push backend requires a separate owner decision.

Before a web deploy:

- Deploy from a checkout that has `web/firebase-config.local.json` with the web
  app configuration and `appCheckSiteKey`. `node scripts/fetch-firebase-configs.mjs`
  retrieves the configuration; the App Check key is preserved from an existing
  file. `npm run build` refuses to package a build without them, because live
  plans, accounts and AI would be silently disabled. Use
  `python3 scripts/package-flutter-web.py --sample` only for local previews.
- Repackaging keeps `dist/.well-known/` and `dist/downloads/` from the last
  Android packaging, so a web-only redeploy doesn't break App Links.
- Hosting sends `Cache-Control: no-cache` (ETag revalidation), because Flutter's
  file names aren't content-hashed. The service worker precaches the shell and
  the CanvasKit renderer only, and bypasses the HTTP cache when installing.

## Android

Signed local files:

- `artifacts/android/MeetHalfway-0.4.0+5.apk` (Android 11+, ARM64).
- `artifacts/android/MeetHalfway-0.4.0+5.aab` (Google Play upload package).
- `artifacts/android/release.json` (checksums, sizes and certificate fingerprint).

The native LiteRT-LM library is bundled. Model weights are a separate opt-in
in-app download. Both packages use the new local release key. Existing debug
installs use a different certificate: preserve live plans through an account
before uninstalling an older development install to replace it.

Build and package:

```sh
bash scripts/flutter.sh build apk --release --target-platform android-arm64
npm run build:android:release
npm run build
npm run package:android
```

The private identity is in `.cache/signing/meethalfway-upload.jks`, with its
passwords in ignored `app/android/key.properties`. Back up both securely; never
commit them. Google Play App Signing uses a separate app-signing certificate,
which must be registered and added to app-link verification after enrollment.

[Firebase Spark Hosting blocks APK/executable files](https://firebase.google.com/support/faq#hosting-exe-restrictions).
The packaging script intentionally excludes installable binaries from `dist/`.
No billing upgrade or extension disguise is used.

Upload preparation is complete for
[Firebase App Distribution](https://console.firebase.google.com/project/meethalfway-2026-e43ca6/appdistribution).
The attempted upload returned the explicit instruction to onboard the app with
**Get started**. No browser control is available in this environment to finish
that console step. After onboarding:

```sh
npm run upload:android
```

This uploads the APK and release notes without specifying testers/groups or
running automated checks. It does not send invitations. Selecting recipients
and public store distribution remain owner actions.

## iOS

Mac compilation run:
https://github.com/lukasboz/HybridAILarp/actions/runs/45330958856

The `ios` job passed. Its `ios-development-unsigned-app` artifact was downloaded and its digest verified. The app is prepared locally at `artifacts/ios/Runner.app`, and a configured unsigned archive is `artifacts/ios/MeetHalfway-0.4.0-configured-unsigned-app.tar.gz`. The previous local app was preserved under its versioned backup name.
Its App Check debug provider is for local development. The install helper
refreshes the public Firebase asset before local signing:

```sh
bash scripts/install-ios.sh artifacts/ios/Runner.app
```

An unlocked, paired iPhone and an existing Apple development identity are needed.
No Android device was listed; iPhone tooling could not retrieve a usable device list during this pass. Paid Apple
team/provisioning, App Store submission, APNs and universal-link capabilities
remain owner-controlled. A production build should use the normal attestation
provider instead of the development debug flag: build it without
`--dart-define=APP_CHECK_DEBUG=true`, which the CI development artifact sets.
`Runner/Distribution.entitlements` requests App Attest (production), Associated
Domains and Push, so enable those capabilities on the paid team's App ID, and
register the app with App Check's App Attest provider in the Firebase console.
`Info.plist` declares standard (exempt) encryption only, so App Store Connect
skips the export-compliance question.

## Source and remaining access

Source branch:
https://github.com/lukasboz/HybridAILarp/tree/codex/complete-hybrid-experience

Open a review:
https://github.com/lukasboz/HybridAILarp/compare/main...codex/complete-hybrid-experience

Publishing through SSH succeeded. The connector returned HTTP 403 for PR
creation, and browser control is unavailable. No new tests or baselines were
written. Existing CI suites are separate from the release compilation result;
see VERIFICATION.md.

Background push requires an explicit billing decision plus web VAPID/APNs and
platform provisioning; setup is in `functions/README.md`. The free live Updates
feed already works without deploying that backend. Actual hardware use, model
quality measurements and any hackathon demonstration recording remain outside
the implemented build evidence.
