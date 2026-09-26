# Verification — version 1.6.0

Recorded 26 September 2026. Validation environment: macOS 26.5.2 on Apple Silicon with Swift 6.3.3. The minimum deployment target is macOS 14; older macOS versions and Intel hardware have not been tested.

## Installable release package

- Built `English-Correct-1.6.0-arm64.dmg` with the signed app, an Applications shortcut, and installation instructions. The package excludes model weights, AI runtimes, test fixtures, logs, and local preferences. `SHA256SUMS.txt` accompanies the download.
- Disk-image verification and a read-only mount passed. The mounted app's signature, version 1.6.0/build 17, arm64 architecture, executable identity, Applications shortcut, and installation text were checked. All dynamic dependencies are macOS system libraries; the unused Xcode toolchain search path was removed before signing.
- The mounted packaged executable passed all **three synthetic local-model correction checks** against LM Studio. This exercises startup after the release-linking change without replacing or launching another copy of the installed app. The full unit suite was not rerun for this packaging-only change; its recorded results remain below.
- The app is Apple Development-signed and is **not notarized**. Gatekeeper rejected its normal assessment; the README and release notes explain first-launch requirements. No security protections were changed. Installation on a separate clean Mac remains unverified.

## Automated results

- The latest full suite executed **292 tests: 290 passed, two opt-in live tests skipped, zero failures**.
- After the first-registration status fix, the final focused run of all **12 login-item tests passed**. This includes an additional regression added after the full-suite run; the complete suite was not rerun after that fix.
- Release **1.6.0 (17)** built successfully and passed strict code-signature verification. This is a local build, not a notarized installer.

The automated suite covers:

- **Consent and input detection:** OS Accessibility permission and per-app approval before field-value reads; secure, disabled, unsupported, and read-only controls; explicit checks while automatic monitoring is paused; whole-input and selected-text checks; empty-input silence.
- **Safe suggestions:** exact original bytes and selection ranges, Unicode offsets, changed fields/apps/configuration, permission revocation, cancellation-ignoring late replies, copy-only controls, replacement readback, and stale draft protection. Tests use an injected Accessibility backend rather than reading personal content.
- **Local AI and setup:** loopback-only endpoints, redirect/proxy restrictions, provider responses and errors, cloud-model rejection, fixed-sample readiness checks without external field reads, first-launch navigation, automatic verification after model selection, cancellation, and automatic suggestions paused after relaunch.
- **Model management:** Fast/Pro catalog identity, LM Studio/Ollama download and deletion protocols, interrupted progress, installed-model verification, explicit selection, and exact-file deletion safeguards. File tests use disposable tiny fixtures; provider tests use injected transports.
- **Presentation and shortcuts:** edit summaries and highlights, bounded and scrollable popup geometry, inactive copy-only/editable panels, shortcut registration/conflicts, and workflow routing. Hidden-view tests verify geometry, not real popup button invocation or VoiceOver behavior.
- **Optional launch at login:** remembered choices, explicit enable/disable, authoritative status readback, pending approval, failures, external status changes, idempotence, and valid-app first-registration status. These tests use an injected backend and isolated preferences; they do not modify real login items.

## Completed live checks

LM Studio downloaded and loaded the official Qwen2.5 1.5B Instruct Q4_K_M Fast model. Production inference corrected synthetic agreement/plural examples and preserved an already-correct sentence. The in-app writing flow displayed and applied a correction. Separate opt-in integration tests passed for setup readiness and whole-input/selected-text correction through the production coordinator with synthetic Accessibility fields.

Native UI inspection covered the main screens, model controls, setup readiness, bundled offline licenses, and the version 1.6.0 startup question in Write and Setup. Physical shortcut delivery and a visible selected-text suggestion were observed during manual use. Production popup renders were inspected for readable text, highlights, and reachable action layout.

## Remaining validation

- **Real cross-app replacement through the live macOS Accessibility UI remains unverified.** Synthetic backend tests do not establish compatibility with every browser or custom editor. Repeat the disposable input-fixture checks in the README for intended apps.
- Live popup button invocation, VoiceOver operation, and complete native glass compositing remain unverified. Offscreen renders omit parts of native compositing. Older macOS versions and a full system appearance/accessibility-settings matrix have not been tested.
- Real login-item registration/unregistration and behavior after sign-out or restart have not been tested. The startup option was not enabled during validation.
- Pro was not downloaded or benchmarked, and Ollama was not tested against a live server. No real downloaded model was deleted during deletion validation.
- Language quality was checked on a small synthetic sample set, not a comprehensive benchmark. Review suggested changes before applying them.

## Reproduce

```sh
swift test
./scripts/build-app.sh
./scripts/build-fixture.sh
```

The normal test suite skips two opt-in live-model tests. With LM Studio serving a downloaded model on its default loopback endpoint, set `ENGLISH_CORRECT_TEST_MODEL` to the identifier reported by that server:

```sh
ENGLISH_CORRECT_LIVE_SETUP=1 ENGLISH_CORRECT_TEST_MODEL=qwen2.5-1.5b-instruct swift test --filter testAppModelSetupWithLiveLocalModel
ENGLISH_CORRECT_LIVE_SHORTCUT_TEST=1 ENGLISH_CORRECT_TEST_MODEL=qwen2.5-1.5b-instruct swift test --filter testLiveLocalModelChecksWholeInputAndSelectedSentenceWhilePaused
```

These opt-in checks send only synthetic sentences to the local model and use isolated preferences and an injected Accessibility backend. They do not test OS delivery. See the README for manual input-fixture checks and the standalone local-model test command.
