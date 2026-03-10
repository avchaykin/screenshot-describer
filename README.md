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
- Sends new images to OpenAI Vision (`gpt-4o-mini`) for screenshot description
- Appends results to `screenshot-descriptions.csv` in the same watched folder
- Sends macOS notifications when:
  - new files are detected
  - processing starts
  - file is processed (or failed)

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
- set/edit **OpenAI API key** via menu item `Edit OpenAI API key…`

API key can also be configured manually via env:

```bash
export OPENAI_API_KEY="sk-..."
```

or with a unified config file (auto-created on first launch if missing):

```json
~/.config/screenshot-describer/config.json
{
  "openai_api_key": "sk-...",
  "working_folder": "/Users/you/Desktop/Screenshots",
  "csv_output_folder": "/Users/you/Documents/screenshot-describer"
}
```

Notes:
- `working_folder` — folder to monitor for new images
- `csv_output_folder` — where `screenshot-descriptions.csv` is written
- if `csv_output_folder` is omitted, CSV is written into `working_folder`
- legacy `~/.config/screenshot-describer/openai_api_key` is still supported as fallback

## Build .app bundle and release zip

```bash
./scripts/build-app.sh
./scripts/make-release-zip.sh
```

Artifacts:
- `dist/ScreenshotDescriber.app`
- `dist/screenshot-describer-macos.zip` (for GitHub Releases)

## Automated Releases (GitHub Actions)

Workflow: `.github/workflows/release.yml`

- Triggers on tag push matching `v*` (example: `v0.1.1`)
- Builds `.app`
- Creates `screenshot-describer-macos.zip`
- Publishes/updates GitHub Release with the zip attached

Publish a new release:

```bash
git tag v0.1.1
git push origin v0.1.1
```

## Notes

Current processing is a placeholder simulation (1.5s per file). Real screenshot description logic can be plugged into `processQueueIfNeeded()` in `screenshot_describer.swift`.
