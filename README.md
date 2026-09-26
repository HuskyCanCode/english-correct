# English Correct

A native macOS writing assistant with local AI, explicit per-app permissions, and suggestions you choose to apply. Requires macOS 14 or later and a local chat model in LM Studio or Ollama.

## Run

From the repository directory, build the app and open it:

```sh
./scripts/build-app.sh
open "dist/English Correct.app"
```

A Swift toolchain is required. You can copy the resulting app to `~/Applications/English Correct.app` before granting Accessibility access; keep it in a stable location afterward. The app has a normal window and a menu-bar shortcut. Closing its window keeps the menu-bar app running; use Quit to exit. Automatic suggestions start paused on every launch. The global keyboard shortcut is available after setup checks pass.

1. Open **Setup**. The guide checks your selected local model using a fixed sample sentence, plus macOS Accessibility, your allowed apps, and shortcut registration. The checks also run on launch; no text is read from another app during setup verification.
2. Start your configured local AI app (LM Studio by default, or an existing Ollama configuration). Open **Models**, download Fast or Pro, and choose **Use Fast / Use Pro**. The selected model is verified automatically after selection or connection changes. Setup shows **Checking…**, then **Ready** when its sample correction succeeds. **Check setup** can retry a failed check.
3. For help in other apps, enable English Correct under macOS **Privacy & Security → Accessibility**, then choose individual apps in **App access**. The app cannot grant permission itself.
4. Once all checks pass, choose **Use shortcut only** or **Enable automatic suggestions**. Automatic suggestions require this explicit choice (or the Write toggle) and start paused again on every launch. If you only need the writing area here, choose **Use only this app** after the model check passes; Accessibility is optional for that path.
5. In an allowed app, click an input and press **⌥⌘E (Option–Command–E)**. Select a sentence first to check only that selection; with no selection, the entire input is checked. Review the result, then choose **Apply** or **Copy**.

The guide opens automatically only on the first launch of a fresh installation. Returning users, including users upgrading from earlier versions, open directly to Write even if setup was left unfinished. The guide stays available in the sidebar and under **English Correct → Setup Guide…**. Readiness checks still run quietly on launch; a failed check shows guidance without opening the setup page. Model/server changes invalidate readiness, pause automatic suggestions, and automatically verify the new selection. Verification never enables automatic suggestions by itself. Losing required permission or the allowed-app selection also pauses monitoring. A successful setup check verifies a basic local correction; it cannot guarantee support for every app’s custom editor.

The shortcut can be changed to **⌃⌥⌘E (Control–Option–Command–E)** in Write or App access if the default is already used by another app. Keep English Correct running. The shortcut shows permission, unsupported-field, local-model, and no-change feedback. Use **Check writing** for the draft inside English Correct itself.

Changed and added words are highlighted in soft green and underlined in both the floating suggestion and the Write screen. Unchanged text stays plain. The before-and-after summary also identifies removed wording. Copy and Apply use the exact corrected text without highlighting or other added formatting.

Empty or whitespace-only inputs stay quiet, including when you press the shortcut: no review starts and no popup appears. Editing a manually checked input dismisses its old suggestion; clearing it cancels the review and keeps late results hidden. A selection containing only whitespace is also skipped.

## Open at login

English Correct asks whether you want it to open when you sign in to your Mac. Choose **Enable open at login** to opt in or **Not now** to dismiss the question. You can change the choice later using **Setup → Open at login**; it is optional and does not block setup or model checks.

The app uses macOS Login Items and reads the actual system status. If macOS requires approval, choose **Open Login Items** to finish in System Settings, or cancel the request. Turning the option off removes English Correct from automatic startup. Changes made in System Settings are reflected when the app becomes active again.

Opening at login does not enable automatic suggestions or grant access to any apps. Suggestions still start paused, and your local AI runtime must be available for writing checks.

## Appearance

Version 1.6.0 uses Apple's native Liquid Glass on macOS 26 or later for sidebar selection, main-window buttons, and the floating suggestion, with native vibrancy behind the main window. Large content cards share that backdrop through subtle translucent fills and borders, avoiding the bright white rims and stacked glass layers of version 1.4.0. Text and accent colors adapt to light and dark appearance. The suggestion keeps its measured text area, scrolling for long corrections, changed-word highlights, and reachable Copy/Apply buttons. These two popup actions use opaque colors to stay readable in a non-focused window: mint with dark green text for Copy and deep teal with white text for Apply in light mode, with corresponding dark-mode colors. They have larger targets and accessibility hints; Apply remains disabled for fields that do not support replacement.

The sidebar contains **Setup**, **Write**, **App access**, and **Models**. Model selection is handled by the Fast and Pro download cards. Connection settings and manual server/model entry are no longer shown; existing local runtime settings are preserved. This version still uses LM Studio or Ollama to run downloaded models.

On macOS 14 and 15, the app uses standard translucent materials and bordered buttons. With **Reduce Transparency** enabled in macOS Accessibility settings, surfaces become opaque and buttons use bordered styles. **Increase Contrast** strengthens surface borders. The app adds no custom motion effects.

## Credits and licenses

Choose **English Correct → About English Correct → Credits & Licenses**, or use **English Correct → Credits & Licenses…** directly from the app menu. The window credits the Qwen team / Alibaba Cloud for the recommended Fast and Pro models, displays copyright and license information, and links to each official model repository and upstream license.

**Read license** opens the complete, selectable license text from the installed app without requiring a network request. Both files are unmodified upstream copies. Their exact repository revisions, integrity hashes, and checked NOTICE-file status are recorded in the bundled `Credits/Sources.json`; neither verified repository contains a separate NOTICE. Attribution does not imply endorsement. Model weights and external LM Studio/Ollama runtimes remain separate downloads.

## Fast and Pro model downloads

Open **Models** to download a suggested model through your configured local AI app. Start LM Studio's local server (0.4+ required for model management) or Ollama first. The app never downloads a model automatically.

| Preset | Model | Download | Mac memory recommendation |
| --- | --- | --- | --- |
| Fast | Qwen2.5 1.5B Instruct, Q4_K_M | About 1.12 GB in LM Studio / 986 MB in Ollama | 8 GB+ |
| Pro | Qwen2.5 7B Instruct, Q4_K_M | About 4.68 GB in LM Studio / 4.7 GB in Ollama | 16 GB+ |

Both model releases use Apache 2.0. **Pro is a local preset, not a paid subscription.** Size estimates come from the published model files and can differ by provider. Memory labels are conservative app guidance rather than vendor minimums. Fast uses less memory; correction quality and speed depend on hardware and text. Review suggestions, especially from smaller models. The interface shows a deterministic summary of the actual changed words rather than displaying model-generated grammar explanations.

- **Download Fast / Download Pro** downloads the model into LM Studio's or Ollama's model library. It does not change the active writing model.
- **Use Fast / Use Pro** explicitly loads/selects that model. The interface offers the recommended Fast and Pro presets. Any model selected before this update remains selected until the user chooses another preset.
- **Delete Fast… / Delete Pro…** removes a downloaded preset after showing its model name and a confirmation. The card returns to **Download Fast / Download Pro**, so you can download it again at any time. Deleting the active model clears the writing selection; download or choose a model before checking more text. Cancel leaves it untouched.
- LM Studio deletion unloads the exact model instances and moves the official Qwen Q4_K_M files to **Trash**. Empty Trash later to recover the disk space. The app reads LM Studio’s configured model folder and supports the official Fast file and both Pro shards; ambiguous, incomplete, symlinked, or other publisher copies must be managed in LM Studio. Ollama unloads and deletes the exact installed tag; shared layers may remain for other models. These libraries are shared with other apps, so deletion affects their access to that model too.
- LM Studio progress is saved using the local server job ID. **Stop checking** stops this app's progress display; the server can continue downloading. Use LM Studio to pause or cancel the actual transfer. After reopening English Correct, **Resume checking** resumes tracking the saved job.
- Ollama **Stop download** closes the pull connection. Retry can reuse partial files cached by Ollama. Progress represents the current model file/layer.
- A successful download is followed by installed-model verification. Incomplete/error responses never make a model selectable. A missing, older, or authentication-protected local server produces an actionable error; this version does not store server API tokens.
- Internet access is required to fetch weights from the model publisher or Ollama registry. Only public model identifiers are sent for downloads; your writing is not part of those requests. Inference continues to use the loopback-only local AI connection.

Fast download and inference were verified with LM Studio and the official Qwen model. Pro and the Ollama download protocol have automated tests; a Pro download and a live Ollama integration test have not been performed. See [verification results](TEST-RESULTS.md) for the validation scope and remaining limitations.

Model attribution and sources:

- [Qwen Fast source](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF) · [Apache 2.0 license](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/blob/main/LICENSE) · [Ollama package](https://ollama.com/library/qwen2.5:1.5b-instruct-q4_K_M)
- [Qwen Pro source](https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF) · [Apache 2.0 license](https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/blob/main/LICENSE) · [Ollama package](https://ollama.com/library/qwen2.5:7b-instruct-q4_K_M)


## Permissions and data

- macOS Accessibility access and the particular app's opt-in are required before reading fields in another app. Automatic monitoring additionally requires the master switch; an explicit shortcut check works while monitoring is paused.
- Only the foreground app's focused, enabled text field is considered. Password fields and unsupported controls are skipped. Automatic checks require a writable field; explicit shortcut checks can offer Copy when direct replacement is unavailable. A target is limited to 4,000 characters (32,000 UTF-8 bytes); a shorter selection can be checked inside a larger field up to 100,000 UTF-16 units.
- Only the selected text is sent to the local model when a selection exists; otherwise the whole input is sent. Automatic checks wait 1.2 seconds, while shortcut checks start immediately. Fields that cannot reliably report their selection are skipped rather than silently broadening the check. The shortcut uses macOS hot-key registration; there is no keystroke recording, clipboard polling, cloud fallback, telemetry, or saved draft history. Copy writes the suggestion to the clipboard only when clicked.
- The app stores whether it has launched before, setup completion, local AI settings, app permissions, download job metadata, and selected model identifiers. Setup readiness is rechecked rather than restored from a previous session. Text and suggestions remain in memory. A local model server may have independent logging settings.
- Only literal loopback or localhost HTTP addresses are accepted. Localhost is pinned to loopback; redirects and proxy use are disabled. Known Ollama cloud aliases are excluded and checked before any text is sent. Use locally downloaded models and keep your server configured for local inference.
- Applying rechecks permission, frontmost app, focused control, selection range, and the exact original field bytes before writing, then verifies the resulting value. Suggestions never apply automatically.
- Permission for a browser covers that browser's accessible fields across websites. Site-specific permissions are not included.

## Compatibility

Standard native text fields and plain multiline controls are supported when they expose their text and selection through Accessibility. Direct replacement requires a writable value or writable selected text. Browser editors and custom controls vary; inaccessible controls are skipped. The app does not use simulated paste as a fallback. Rich formatting is not preserved by a whole-field plain-text replacement. Review suggestions before applying them; model output can be incorrect.

This is a local build, not a notarized installer. The build script uses the single available Apple Development or Developer ID Application signing identity, if present, so subsequent builds can retain the same certificate-backed identity. Otherwise it uses ad-hoc signing. Set `ENGLISH_CORRECT_SIGNING_IDENTITY` to explicitly select an identity (or `-` for ad-hoc signing). It never silently falls back after a signing failure. Keep the app in a stable location after granting Accessibility. Moving it or changing its signing identity may require removing and re-adding it in macOS Accessibility settings; ad-hoc rebuilds can also require this refresh.

## Build and test

A Swift toolchain is required; no third-party package dependencies are used.

```sh
swift test
./scripts/build-app.sh
./scripts/build-fixture.sh
ENGLISH_CORRECT_TEST_MODEL=qwen2.5-1.5b-instruct .build/release/EnglishCorrect --test-local-ai
```

The live-model test uses synthetic sentences and checks agreement, plurals, and preserving an already-correct sentence. Override `ENGLISH_CORRECT_TEST_URL` and `ENGLISH_CORRECT_TEST_MODEL` to test a different local server/model. Pass `--ollama` for an installed Ollama server.

`Tests/EnglishCorrectCoreTests` covers local API validation, provider responses, network errors, no remote redirects, cloud-model rejection, and stale request protection. `Tests/EnglishCorrectAppTests` covers the actual monitor using an injected Accessibility backend plus app settings and result invalidation. These tests do not grant OS access or inspect personal content.

The separate `dist/English Correct Input Test.app` contains disposable native single-line, multiline, password, and read-only controls for manual end-to-end testing. Grant English Correct Accessibility access and allow Input Test. With automatic suggestions paused:

1. Choose **Use whole input**, then press **⌥⌘E**. Both sample sentences should be checked. Review and apply.
2. Reset, choose **Select second sentence**, and press **⌥⌘E**. Only the second sentence should appear in the suggestion and change on apply; the first remains untouched.
3. Change the text or selection while inference runs. The old suggestion must be discarded. Switch apps and verify the same protection.
4. Focus the password field and trigger the shortcut. It must report that password fields are skipped without requesting a correction.
5. Revoke Input Test access and verify that the shortcut offers setup guidance. Automatic checks must also stop.

Read-only/custom inputs that expose readable text and selection may offer Copy on explicit checks; they must never allow Apply. Some read-only native labels do not expose a text-field role and are skipped entirely.

See [verification results](TEST-RESULTS.md) for completed checks and remaining limitations.

## Implementation references

- [Apple Accessibility permission API](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- [Apple Accessibility value updates](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)
- [Apple Liquid Glass adoption](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) and [SwiftUI glass containers](https://developer.apple.com/documentation/SwiftUI/GlassEffectContainer)
- [LM Studio structured output](https://lmstudio.ai/docs/developer/openai-compat/structured-output)
- [Ollama generation API](https://docs.ollama.com/api/generate)

- [LM Studio download API](https://lmstudio.ai/docs/developer/rest/download) and [progress API](https://lmstudio.ai/docs/developer/rest/download-status)
- [Ollama pull API](https://docs.ollama.com/api/pull)
- [Ollama delete API](https://docs.ollama.com/api/delete) and [unload via generate](https://docs.ollama.com/api/generate)
- [LM Studio unload API](https://lmstudio.ai/docs/developer/rest/unload), [model folder structure](https://lmstudio.ai/docs/app/advanced/import-model), and [maintainer guidance on deleting model files](https://github.com/lmstudio-ai/lms/issues/199)
