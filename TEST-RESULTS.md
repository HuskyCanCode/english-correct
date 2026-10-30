# Version 1.7.5 expressive Slang validation

- Full suite: 331 tests, 329 passed, two optional legacy live tests skipped, zero failures.
- Slang now uses fixed examples of playful idioms and a literal sentence that should stay unchanged. The original user text remains its own JSON payload. Formal and Casual instructions are unchanged, and Casual remains the default.
- The built-in Fast model returned “Let me noodle on it” for “Let me think,” “I need to noodle on this proposal before I decide” for the longer thinking example, and “I'm swamped today” for the busy-day example. It preserved “I put the noodles in the soup” without adding an unrelated idiom.
- The app's live smoke command passed those four Slang cases, the three style cases, and three grammar/preservation cases. This is a small synthetic quality sample; wording can vary. Pro and live Ollama inference remain unverified.
- The 1.7.5/build 23 DMG passed integrity, mounted-app, and strict signature checks. It remains Apple Development-signed and is not Apple-notarized.

# Version 1.7.4 writing-style and model-label validation

- Full suite: 331 tests, 329 passed, two optional legacy live tests skipped, zero failures.
- Tests verify Casual defaults, saved/invalid preferences, the selected model label, and style instructions for all supported providers. Built-in runtime configuration carries the selected style into inference.
- Changing style regenerates the original selected passage or whole input immediately. Late results from the previous style are discarded; changed source text is not reviewed or replaced. Readiness and automatic-suggestion preferences remain intact.
- The packaged built-in Fast model passed the three grammar/preservation smoke cases and all three style cases on synthetic text. The same informal report request became “Can you please send me the report when you have the opportunity?” in Formal, standard conversational wording in Casual, and relaxed abbreviations in Slang. This is a small quality check, not a broad writing benchmark; model wording can vary.
- The 1.7.4/build 22 DMG passed integrity, mounted-app, and strict signature checks. It is Apple Development-signed and is not Apple-notarized.
- In a disposable native component preview, the production suggestion view displayed the Fast model name and Casual default. Selecting Slang and Formal changed the selected control and regenerated the preview. This used an injected corrector and synthetic Accessibility fields; live model quality and arbitrary third-party editor compatibility are separate checks.

# Version 1.7.3 Return-to-accept validation

- Full suite: 324 tests, 322 passed, two optional legacy live tests skipped, zero failures.
- A real Return key press in a disposable native text window accepted a visible suggestion through the production Carbon shortcut and Apply path. The popup closed; the next Return inserted a normal newline. This used synthetic text and an injected Accessibility backend, without reading or editing personal app content.
- Tests cover registration cleanup, conflicts/fallback, loading/copy-only/dismissed popups, changed source text, and revoked permission. Return never wrote text for an invalid review.
- Hidden popup layout tests do not reserve Return. Direct editing in arbitrary third-party fields still depends on their Accessibility support.

# Version 1.7.2 automatic-suggestion timing validation

- Full suite: 320 tests, 318 passed, two optional legacy live tests skipped, zero failures.
- Timing tests confirm the configured pause is used before automatic inference, a changed delay invalidates the previous timer, and manual keyboard checks bypass the delay even when the preference changes mid-request.
- Preferences restore the chosen interval without enabling automatic suggestions. Invalid or non-finite saved/settings values are normalized to the supported 0.3–10 second range.
- The default remains 1.2 seconds. Model processing time is additional; this setting does not promise an exact popup arrival time.

# Version 1.7.1 automatic-suggestions validation

- Full automated suite: 315 tests, 313 passed, two optional legacy live tests skipped, zero failures.
- Regression checks confirm Setup → Write navigation preserves active automatic suggestions without reading a field during navigation.
- Explicit On/Off choices persist. A saved On choice waits for the sample-model check, Accessibility, app approval, and shortcut registration after restart. Explicit Off cancels pending startup restoration.
- Menu-bar Pause suggestions saves Off. Permission/model revocation still pauses the active session.

# Version 1.7.0 built-in engine validation

- The full automated suite executed 313 tests: 311 passed, two optional legacy live tests skipped, zero failures.
- A clean, isolated model folder downloaded the official Fast GGUF through the production URLSession downloader and verified its pinned size and SHA-256. No LM Studio/Ollama API was used.
- The packaged llama.cpp engine loaded that file and passed three real correction cases: agreement, agreement/plurals, and preservation of an already-correct sentence. Its child process exited after shutdown.
- Fixture tests cover corrupted downloads, canceled transfers, partial Pro shards/retry, deletion/re-download, symlink rejection, fresh-install defaults, legacy selection preservation, bearer authentication, and loopback-only engine arguments. No user model was deleted.
- The DMG passed integrity and mounted-app checks. Nested executable/library signatures passed strict verification; all runtime dependencies are bundled or macOS system libraries, and declared deployment targets are compatible with macOS 14.
- The app includes the engine but not model weights. It remains Apple Development-signed and is not Apple-notarized. A separate clean Mac, real Pro inference, Intel, and older macOS versions have not been live-tested.

The previous version's detailed checks and limitations follow.

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
