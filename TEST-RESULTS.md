# Version 1.7.8 source verification

- Final full suite on 30 October 2026: 393 tests executed, 391 passed, two optional legacy live tests skipped, zero failures. This includes appearance, popup geometry, shortcut lifecycle, Unicode highlighting, guarded Undo, download/provider, and existing cursor-restoration regressions.
- The final app build and installed executable match, and strict deep signature verification passed. Soft Blue is the final Light palette; Dark colors, native backdrop blur, and accessibility fallbacks are preserved.
- Source review found no blocking issues or captured writing/credentials in the changed files. Generated apps, installers, test fixtures, logs, and model weights remain excluded from Git. Cursor diagnostics are opt-in metadata only; the experimental text-marker resolver is not integrated into production correction.
- This push updates source and documentation. README download links continue to point to the published 1.7.7 installer. The reported ChatGPT cursor reset and real backdrop-compositing verification retain the limitations recorded below.

# Soft Blue Light palette

- Applied the user's final Soft Blue choice: #F7FAFD off-white backgrounds, #DCEAF6 mist-blue action buttons and changed-word highlights, and #22384A navy text. Sidebar, card, border, badge, and secondary colors use coordinated soft blues. All 15 existing Dark palette roles match their prior values; native blur, opacity, and correction behavior are unchanged.
- Opaque button/highlight text contrast is 9.89:1, including 8.31:1 for pressed suggestion actions. Primary text on the solid backdrop is 11.57:1. Secondary labels on tinted cards are 5.31:1 and disabled labels are 5.47:1. Native glass may mute inactive controls, and backdrop compositing varies; these ratios describe the specified solid fills.
- All 19 existing appearance, suggestion geometry, inactive-action footer, and highlighting checks passed. The live Light main-window palette and layout were inspected. The signed app passed strict deep signature verification, was installed with an identical executable hash, and restarted.
- The saved Light appearance, Casual style, and 0.3-second timing were retained. Automatic suggestions resumed after the startup model check. The Write page was returned to its initial scroll position.

# Soft Blush Light buttons

- Light action buttons and control tint use #F4DADD Soft Blush, with dark plum #42323A labels. The popup has separate action-fill and text-accent roles so Apply, Copy, and Undo receive blush fills while links, status text, and icons retain deep rose. Dark palette values and the prior Dark prominent-action fill are preserved.
- Opaque suggestion labels have 9.10:1 contrast normally and 7.67:1 with the existing pressed overlay. Disabled semantics and cream disabled fills remain intact. Native Light buttons explicitly receive dark labels; writing-style options retain explicit readable text styling.
- All 19 existing appearance, geometry, inactive-action footer, and highlighting checks passed after the final modifier refinement. Native Light Setup buttons and writing-style labels were visually inspected. The modifier retains content identity when appearance changes. Existing blur and correction behavior are unchanged.
- The final signed app passed strict deep verification, was installed with an identical executable hash, and restarted. Automatic suggestions resumed. The latest user-selected Light appearance was left in place after previewing.

# Pastel Pink/Cream/Blue Light palette

- Applied the latest light-only reference: #F5C7C9 blush cards/sidebar, #EFE4D4 cream backdrop, #F8819B pink glass tint, and #B9D9EA Copy actions and changed-word highlights. Companion off-white surfaces, deep rose #A02D50 actions, and plum text keep the pastel palette readable. All 14 Dark palette roles were compared against the prior values and are unchanged.
- Opaque Apply labels have 7.03:1 contrast, including 6.35:1 when pressed. Copy/highlight text is 8.11:1, including 6.86:1 for pressed Copy. Secondary labels on blush are 5.29:1; disabled labels on cream are 6.36:1. Native blur, transparency, accessibility fallbacks, and correction behavior are unchanged.
- All 19 existing appearance, suggestion geometry, inactive-action footer, and highlighting checks passed. The production Light popup render was reviewed. The final signed app passed strict deep signature verification, was installed with an identical executable hash, and restarted in the saved Light appearance.

# Cream/Teal Light and Blue/Lavender Dark palettes

- Replaced the previous palettes with the latest references: #244855, #E64833, #874F41, #90AEAD, and #FBE9D0 in Light; #3D52A0, #7091E6, #8697C4, #ADBBDA, and #EDE8F5 in Dark. Derived deep-blue surfaces, lighter sage surfaces, and a deeper orange text/action shade preserve contrast. Native controls use deep blue in Dark so their light labels stay readable, while custom suggestion actions have explicit opaque fills and foreground colors.
- Opaque suggestion Apply contrast is 5.05:1 in Light and 8.83:1 in Dark; Copy is 8.28:1 and 11.87:1. Highlighted changes are 7.23:1 and 5.99:1. Secondary/disabled labels on the tinted surfaces are 4.79:1 and 6.25:1. Native blur, transparency, accessibility fallbacks, and correction behavior are preserved.
- All 19 existing appearance, suggestion geometry, inactive-action footer, and highlighting checks passed after the final control-color change. Light and Dark production popup renders and live main-window palettes were inspected. Window captures do not establish real backdrop compositing.
- The final signed build passed strict deep signature verification, was installed with an identical executable hash, and restarted. The user's Dark appearance, timing, and writing style were retained.

# Blush Light and Navy Dark palettes

- Applied the user's separate reference palettes: warm white, dusty blush, and rose actions in Light; charcoal, navy, slate, and pale blue actions in Dark. The app, auxiliary windows, suggestion actions, and changed-word highlights share adaptive theme colors. Existing native blur, translucency, and accessibility fallbacks are preserved.
- Opaque suggestion Apply text contrast is 6.12:1 in Light and 12.44:1 in Dark. Copy text is 8.72:1 and 11.93:1; highlighted text is 8.72:1 and 5.89:1. Disabled actions retain disabled semantics and opaque fills, with text contrast above 5.4:1.
- All 19 existing appearance, suggestion geometry, inactive-action footer, and highlighting checks passed. The production dark opaque popup and light popup text/buttons were visually inspected. Live main-window Light and Dark appearances were reviewed; window captures do not establish live backdrop compositing.
- The signed build passed strict deep signature verification, was installed with an identical executable hash, and restarted. Automatic suggestions resumed with the saved timing and Casual style. The user's Dark appearance was restored after checking Light.

# Native translucent and blurred backgrounds

- Reduced stacked mint fills so the native window backdrop is visible through content cards and the sidebar. Main, About, and Credits windows use clear, nonopaque window backing. The suggestion uses one rounded native popover material rather than stacked whole-card materials; action buttons and text remain opaque.
- Added a shared NSVisualEffectView bridge with behind-window blending, active material, light/dark/high-contrast appearance, and a cached stretchable rounded material mask. Controls retain Liquid Glass where available. Reduce Transparency and the existing forced-opaque environment bypass the blur view and draw solid surfaces.
- All 19 existing appearance, suggestion geometry, inactive-action footer, and highlighting checks passed. No correction, Undo, keyboard, model, or app-access behavior was changed.
- A temporary, synthetic striped backdrop was opened for visual verification. The computer-use tool returns flattened JPEG window captures without backdrop color variation; these establish layout and text readability, not real WindowServer compositing. A direct user visual check was requested and remains pending.
- The final signed app passed strict deep signature verification, was installed with an identical executable hash, and restarted; automatic suggestions resumed. The temporary backdrop was closed afterward. The current macOS Reduce Transparency and Increase Contrast preferences are both off; no system accessibility settings were changed.

# Mint & Teal appearance refinement

- Applied the selected palette: #EDF8F5 background, #237264 actions, #183F38 text, and #C9EADF change highlights. Cards, sidebar, glass, model badges, and auxiliary windows use coordinated mint colors; dark appearance uses deep teal surfaces and pale mint actions.
- Inactive suggestion buttons retain opaque fills. Enabled button text contrast is 5.73:1–9.80:1, and change highlights are 7.17:1–9.03:1 across appearances. Disabled styling and accessibility fallbacks are preserved.
- All 14 existing suggestion geometry, inactive-panel footer, and highlighting checks passed. The dark opaque production-popup render and live light/dark main windows were visually inspected.
- The signed app passed strict deep verification, was installed and restarted, and reached ready with automatic suggestions on. Appearance was returned to System after validation. Existing Undo, keyboard routing, model selection, and writing settings were preserved.

# Version 1.7.8 local build: popup polish, appearance, and Undo

- Full suite: 393 tests, 391 passed, two optional legacy live tests skipped, zero failures.
- The popup uses a compact model badge, one keyboard-hint line, quieter borders, and a smaller post-Apply notice. Return is released before the notice appears. Escape registers only while a popup is visible, including loading, errors, copy-only reviews, and Undo; stale callbacks and registration conflicts have tested cleanup and fallbacks.
- A persisted System/Light/Dark choice in the sidebar changes the app's appearance, including its panels and auxiliary windows, without changing macOS settings. Live Light and Dark views were visually checked, and System was restored afterward. All three choices remain reachable in the sidebar.
- Undo is offered for eight seconds where the editor supports safe whole-field restoration. It holds one receipt in memory and requires the same authorized, focused, enabled, nonsecure field and exact accepted text bytes. Typing, focus/permission changes, expiry, dismissal, and newer requests clear the offer. Text is written once and verified; delayed acceptance caret work is canceled before restoring the original. Draft Undo is available until the applied draft changes.
- Sixteen OS-boundary Undo tests cover Unicode, selected passages, changed input/focus/access, unsupported editors, metadata races, protection changes during writing, failed verification, and cancellation. Workflow tests cover polling without repeated reviews, expiry races, immediate typing before Undo, draft edits, and Escape across all popup states.
- In a disposable native NSTextView with a synthetic Accessibility backend, the production component applied and undid a whole sentence and a selected sentence with an emoji prefix and untouched suffix. The original wording and surrounding bytes were restored, and the native fixture reported the expected caret positions. This is not a verification of arbitrary third-party editor support.
- Desktop automation's simulated Escape did not trigger the global Carbon binding in the fixture. Shortcut lifecycle/routing was verified with injected keyboard backends; physical/global Escape delivery remains unverified. No messages were sent from another app.
- Build 26 passed strict deep signature verification, was installed at /Applications/English Correct.app, restarted, and reached ready with automatic suggestions restored. It is a local build; no 1.7.8 GitHub release was published in this task. The separately reported ChatGPT cursor issue remains under investigation.

# Earlier light blue theme

- Applied the approved palette: #EDF6FF window, #F5FAFF cards, #245D94 buttons, #17324D navy body text, and #CCE5FF highlights. Navigation, secondary text, glass, controls, and auxiliary windows share the blue theme and adapt to system appearance. Reduce Transparency keeps opaque blue surfaces, and Increase Contrast retains stronger borders.
- Suggestion actions retain solid fills even in an inactive panel. Enabled button text contrast is 6.84:1–11.07:1; highlighted changes exceed 8:1 in both appearances. Navy body text exceeds 12:1 on the opaque light window and card colors.
- All 14 existing suggestion layout, inactive-panel footer, and correction-highlighting tests passed. A dark opaque production-view render was visually checked. Offscreen glass renders omit native compositing and are not evidence of the live glass color.
- The signed app built, passed strict deep signature verification, was installed, and restarted. Live Write, App access, and Models views showed the blue palette. Accessibility remained granted, the local model became ready, and automatic suggestions resumed with the remembered timing and writing style.
- This appearance update does not establish a fix for the separately reported ChatGPT cursor issue.

# Version 1.7.7 delayed cursor-reset validation

- Full suite: 350 tests, 348 passed, two optional legacy live tests skipped, zero failures.
- The installed previous version was confirmed as 1.7.6/build 24 with the same binary as its release. Its single immediate caret write did not handle an editor resetting selection during a later render.
- After successful replacement, the app now checks the cursor after 60, 180, and 360 ms of scheduled waits. A readable collapsed zero position can be repaired even when settable metadata is inaccurate. These checks never rewrite the accepted text.
- Exact resulting bytes, focused field/app, permissions, nonsecure/enabled state, and an apply generation are checked. Typing, repeated navigation keys, clicks, dragging, or scrolling cancel cursor updates. Key/click releases are ignored. Only aggregate event ages are read, without key contents or event recording.
- Deterministic regressions cover delayed resets, ignored successful range writes, inaccurate metadata, Home/navigation to zero, selections and other caret positions, changed text/focus/permissions/protection, new applies, monitor stop, Unicode offsets, and Return repair continuing after the popup closes. Immediate restoration also respects interaction during slow replacement/confirmation.
- A disposable real NSTextView deliberately reset its cursor to zero 30 ms after insertion. The production coordinator repaired it: the whole-input case recorded one reset and two caret writes at UTF-16 position 19, and subsequent typing appended “ Next.”. The selected-passage case preserved its emoji prefix and suffix, recorded a repair at position 32, and inserted “ More.” immediately before untouched following text. Native interaction used Apply with a synthetic Accessibility backend; Return routing was verified by automated workflow tests.
- The 1.7.7/build 25 DMG passed integrity, mounted-app, and strict signature checks. The installed Applications copy was backed up, updated to the exact checked binary, restarted, and reached ready with its remembered automatic-suggestion preference restored. This build remains Apple Development-signed and is not Apple-notarized. Arbitrary third-party editors and physical/global Return delivery were not reverified.

# Version 1.7.6 cursor-after-acceptance validation

- Full suite: 336 tests, 334 passed, two optional legacy live tests skipped, zero failures.
- Successful replacements now collapse the cursor after the inserted correction. Selected-passage replacements leave it before untouched following text. Tests cover both text-write methods, whole-input/manual/automatic requests, emoji, combining characters, and UTF-16 offsets.
- Cursor positioning rechecks the field, exact resulting text, and permissions. Unsupported or failed cursor writes keep the successful text replacement and never retry it. Changed focus/text and revoked access prevent cursor writes; failed or unverified text replacements do not move the cursor.
- Return workflow tests verify the shared Apply path restores the cursor, closes the popup, and releases Return. Continued typing after a selected correction preserves surrounding text.
- A disposable real NSTextView behind a synthetic Accessibility backend confirmed typing after Apply: “She went yesterday. Next.” for whole input, and new text inserted between the corrected selected passage and its untouched suffix, with an emoji prefix preserved. The native automated Return attempt inserted a newline rather than activating acceptance, so physical/global Return delivery was not re-established in this session; Return routing was verified with an injected keyboard backend. Arbitrary third-party editors remain unverified.
- The 1.7.6/build 24 DMG passed integrity, mounted-app, and strict signature checks. It remains Apple Development-signed and is not Apple-notarized.

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
