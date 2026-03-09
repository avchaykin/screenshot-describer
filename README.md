# screenshot-describer

Menubar macOS service that watches a configured working folder and triggers processing when new files appear.

## Implemented now

- Installable with Homebrew as a **cask app**
- Packaged as a real `.app` bundle (`ScreenshotDescriber.app`)
- Menubar icon with statuses:
  - `🟢` idle
  - `🟠` processing
- Menu settings:
  - choose working folder
  - reset working folder
  - toggle **Launch at login**
  - quit app
- Watches working folder for new files and starts processing queue
- Sends macOS notifications when:
  - new files are detected
  - processing starts
  - file is processed

## Build locally

```bash
swift build -c release
```

Binary:

```bash
.build/release/screenshot-describer
```

## Homebrew install (cask)

This repo includes a cask at `Casks/screenshot-describer.rb`.

Typical flow (from your tap repo):

```bash
brew tap avchaykin/tap
brew install --cask screenshot-describer
```

Start once from Applications, then configure from menubar:
- choose working folder
- optionally enable **Launch at login**

## Build .app bundle and release zip

```bash
./scripts/build-app.sh
./scripts/make-release-zip.sh
```

Artifacts:
- `dist/ScreenshotDescriber.app`
- `dist/screenshot-describer-macos.zip` (for GitHub Releases)

## Notes

Current processing is a placeholder simulation (1.5s per file). Real screenshot description logic can be plugged into `processQueueIfNeeded()` in `screenshot_describer.swift`.
