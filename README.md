# Meta Study (`meta-ati`)

An iPhone study app for Meta Ray-Ban Display glasses. After you tap **Start study**, it recognizes a steady practice question, requests an educational answer and rationale, and sends readable cards to the lens. No spoken or typed prompt is required for each question.

**This repository contains source code, not an installed iPhone app.** A signed build and physical-glasses testing are still required. An unsigned GitHub Actions artifact cannot be installed directly on an iPhone.

## What is implemented

- Meta DAT 1.0.1 camera and display capabilities attached to the **same DeviceSession**, with registration, camera permission, URL callbacks, lifecycle/error handling, readiness timeout, and frame-loss handling.
- Apple Vision OCR on the iPhone, sampled at most once every 0.8 seconds. Recognition runs off the main actor; only one OCR task runs at a time.
- Automatic detection of English, single-column multiple-choice and SATA questions labeled **A–D through A–F**. Two matching observations spanning at least 1.2 seconds are required.
- A best-effort stream still capture when a new complete question appears, plus a manual **Capture still** button. This is **not** the experimental full-resolution standalone Photo API; better sharpness is not guaranteed.
- One AI request at a time, at least eight seconds between attempts, up to 64 cached results per session, and cancellation/invalidation when the view changes. Failed AI requests stop the study session instead of repeatedly charging the account.
- Google Gemini structured answers with label validation, explanations, mnemonics, paginated lens cards, and optional iPhone speech output. The audio route depends on the phone's current output settings.
- A **Practice image** source for testing OCR and AI with an image selected on the iPhone, without connected glasses.
- If the glasses SDK cannot initialize (including in some simulator environments), the app opens in Practice image mode. It does not claim that the glasses are connected.
- Personal API key entry in Settings, stored in the device-only Keychain. The key is not embedded in code or included in a URL.
- Unit tests for parsing, steadiness, deduplication, cooldowns, stale completions, request construction, malformed model responses, and answer-label validation.

## Phone-only status

You can review the code and [build results](https://github.com/ameralqraishi9-lang/meta-ati/actions) from your phone. GitHub Actions is configured to compile the app and run its core tests on a hosted Mac, without your own Mac or any Apple signing credentials.

To use the app on a real iPhone, the remaining installation route is an **Apple-signed build** (for example TestFlight through an Apple Developer account and an authorized build service). This repository does not enroll an Apple account, create signing credentials, upload to App Store Connect, or promise a phone-only installation shortcut. No API key or Apple password should be posted to this public repository.

## First use after installation

1. Open **Settings** in Meta Study and save your personal [Gemini API key](https://aistudio.google.com/apikey). The model ID is editable; the initial value is `gemini-3.8-flash`.
2. For glasses: enable Meta Developer Mode, tap **Connect app in Meta AI**, then **Allow glasses camera**. Return to Meta Study and tap **Connect camera and lens**.
3. Confirm you are using permitted practice material and tap **Start study**. Keep the app in the foreground and the complete question steady in view.
4. The first card shows the answer and short explanation. **Next** on the lens moves through the rationale and mnemonic. The iPhone also shows the full explanation and recognized text for checking.
5. **Stop study** stops OCR and AI. **Disconnect** also ends the camera/display connection. Moving the app to the background stops both automatically.

## Build and validation

Open `MetaStudy.xcodeproj` with **Xcode 26.4 or newer**; the cloud workflow uses Xcode 26.6. The deployment target is iOS 17.2. The SDK is pinned to 1.0.1.

```sh
swift test
xcodebuild build -project MetaStudy.xcodeproj -scheme MetaStudy \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

The project is committed, so no project generator is required to open it. `python3 scripts/generate_project.py` regenerates it deterministically after app source files change.

For local signing, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your Apple team and unique bundle identifier. The local file is ignored by Git. Meta Developer Mode uses `META_APP_ID = 0`; production registration needs your own Meta app configuration and release-channel access. A production release also needs its own app icon and distribution configuration.

## Relationship to VisionClaw

Your separate [VisionClaw fork](https://github.com/ameralqraishi9-lang/visionclaw) remains unchanged. Its inspected revision `3f39807058c5ddf9faf763de3cbc70aa0b5f6fad` uses a voice-agent gateway. This repository is a focused companion implementation using the same Meta DAT approach, with direct text-only Gemini requests and no voice-agent server requirement.

`StudyController.receive(_:isStill:)` is the integration entry point for decoded `UIImage` frames if the study feature is later merged into VisionClaw. Do not run two independent Meta sessions for the camera and display. This repository has a complete standalone Xcode app target; it is not already wired into the separate VisionClaw fork.

## Limits and data handling

- OCR can misread negation, drug names, units or digits. It can miss a cropped last choice even when A–D are visible. The app checks confidence and labels but cannot prove a question is complete. Always inspect the recognized text and verify AI explanations against course materials.
- It does not recognize unlabelled choices, arbitrary layouts, image-based clinical questions, or all assessment formats. No claim of clinical accuracy or official ATI affiliation is made.
- Practice-only consent and explicit assessment-banner checks help limit unintended use. They are best-effort checks, **not a reliable exam/proctor detector**. This app is for authorized studying, not active graded, timed or proctored assessments.
- Camera images are processed locally and are not uploaded by the AI client. Recognized question text is sent to Google's Gemini API. Provider retention, account terms, quotas and charges apply.
- Results and recognized text remain in memory for the session; stopping clears them. The app does not write a question history. The personal key stays in the iPhone Keychain until deleted in Settings or removed from the device.
- Full-resolution standalone capture is experimental in this SDK and is not included. In-stream still capture may remain less sharp than a normal phone photo.
- Actual camera quality, lens delivery, audio routing, permissions, battery use and reconnection must be tested on the user's iPhone/glasses. A successful compile or unit test does not establish those hardware results.

## Sources

API usage was checked against the official SDK documentation and the 1.0.1 Swift interfaces:

- [Meta DAT iOS SDK and developer terms](https://github.com/facebook/meta-wearables-dat-ios)
- [CameraAccess sample](https://github.com/facebook/meta-wearables-dat-ios/tree/main/samples/CameraAccess)
- [DisplayAccess sample](https://github.com/facebook/meta-wearables-dat-ios/tree/main/samples/DisplayAccess)
- [Gemini structured output](https://ai.google.dev/gemini-api/docs/generate-content/structured-output)
- [Gemini model IDs](https://ai.google.dev/gemini-api/docs/models)

See [VALIDATION.md](VALIDATION.md) for the checks actually completed and the remaining device checks.
