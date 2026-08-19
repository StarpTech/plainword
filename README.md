<div align="center">
  <img src="Resources/SharedAssets.xcassets/AppIcon.appiconset/AppIcon-1024.png" alt="Plainword app icon" width="128" height="128">
  <h1>Plainword</h1>
  <p><strong>Say what you mean, wherever you write.</strong></p>
  <p>A programmable writing assistant for macOS that runs on the AI provider of your choice.</p>
</div>

Plainword corrects, rewrites and transforms text directly in the app you are writing in — macOS text fields, browsers, Slack, WhatsApp, LinkedIn, mail clients. Select a phrase or put the cursor in a paragraph and press **Command–F2**: it proposes an edit and waits for you to accept it. Press **Shift–Command–F2** to give it an instruction of your own — "shorter", "less formal", "keep the second sentence" — on the selection or the whole focused field.

A spell checker knows the rules of a language. It does not know how you write, what the thread above is about, or which model you want to use.

## What it does

- **Writes in your tone and style.** Pick a tone and style and add standing instructions such as "British English, no semicolons". Every request carries them, so suggestions sound like you instead of like generic AI output.
- **Uses the text around your cursor.** Plainword sends the selection together with the surrounding paragraph and whatever context the app exposes through macOS, so a reply in a thread is edited as a reply rather than an isolated sentence.
- **Runs on any LLM.** A local model through Ollama, your signed-in Codex subscription, or any OpenAI-compatible endpoint with your own key. Switch provider or model whenever you want; there is no Plainword subscription on top.

## The two shortcuts

1. **Pick the text.** Select a phrase or leave the cursor inside a paragraph.
2. **Press Command–F2.** Plainword works on that selection or paragraph only.
3. **Accept or dismiss.** Small corrections are marked in place; larger rewrites appear in a comparison card next to your writing.

**Shift–Command–F2** goes directly to the instruction prompt. It transforms the exact selection when there is one, and otherwise the whole focused field without changing what is visibly selected.

<div align="center">
  <img src="docs/images/transform-entire-field.png" alt="Plainword transform popover targeting an entire focused field" width="600">
  <p><em>The transform shortcut opens the instruction prompt immediately; no provider request starts until you submit it.</em></p>
</div>

## What it does not do

Plainword stays inert while you type. Typing and selecting text never opens the interface or contacts your provider.

- Every request starts with a keystroke from you.
- Nothing is applied without your confirmation.
- Password and secure fields are ignored.
- No clipboard access, no screen capture.
- Any app can be excluded.
- Provider credentials live in the macOS Keychain. Codex reuses the Codex CLI login instead of storing a second credential.
- With Ollama, your text is processed entirely on your Mac.

> [!NOTE]
> Plainword is an early macOS project. Compatibility varies because each app exposes its text fields differently. If an app cannot safely expose editable text, Plainword leaves it alone.

## Download the preview

Unsigned universal DMG preview builds are available from [GitHub Releases](../../releases). They run on Apple Silicon and Intel Macs.

### Opening the unsigned preview

Only override Gatekeeper if you downloaded the DMG from this repository and trust the release. An unsigned app has not been checked by Apple.

1. Download the DMG and its `.sha256` file from the same GitHub release.
2. Optionally verify the download in Terminal with `shasum -a 256 ~/Downloads/Plainword-*-unsigned.dmg`, then compare the result with the downloaded `.sha256` file.
3. Open the DMG and drag **Plainword** into **Applications**.
4. Try to open Plainword from Applications. macOS will block it; dismiss the warning.
5. Open **System Settings → Privacy & Security** and scroll down to **Security**.
6. Click **Open Anyway** next to the message about Plainword. This option is available for about one hour after the blocked launch attempt.
7. Authenticate when prompted, then confirm by clicking **Open**.

macOS saves an exception for that copy of Plainword. You still need to grant Plainword Accessibility access when the app requests it. See [Apple's instructions for opening an app from an unidentified developer](https://support.apple.com/guide/mac-help/mh40616/mac).

## Try Plainword

You will need macOS 14 or newer, the current stable Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). You will also need [Ollama](https://ollama.com/) for local processing, a signed-in [Codex CLI](https://learn.chatgpt.com/docs/codex/cli) account, or access to an OpenAI-compatible provider.

```sh
brew install xcodegen
make run
```

When Plainword opens:

1. Under **Provider**, choose **Ollama**, **Codex**, or add an OpenAI-compatible service. For Codex, run `codex login` once in Terminal and sign in with ChatGPT.
2. Pick a tone and style under **Writing**.
3. Under **General**, choose **Allow Access** and enable Plainword in macOS System Settings.
4. Focus a supported text field in another app and press **Command–F2**.

## For contributors

```sh
make project     # Regenerate the Xcode project
make test-core   # Run core tests
make build       # Build the macOS app
make verify      # Run tests and a full build
```

`project.yml` is the source of truth for the generated Xcode project. Local builds do not require an Apple Developer team, although macOS may ask you to grant Accessibility access again after an unsigned rebuild.

For more detail, see the [architecture and security notes](docs/ARCHITECTURE.md), [Codex provider guide](docs/CODEX.md), [provider compatibility guide](docs/CHAT_COMPLETIONS.md), and [release checklist](docs/RELEASE_CHECKLIST.md).
