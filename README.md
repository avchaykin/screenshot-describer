# screenshot-describer

Menubar macOS service that watches a configured working folder and triggers processing when new files appear.

## Implemented now

- Installable with Homebrew (formula included)
- Runs as a background service (`brew services`)
- Menubar icon with statuses:
  - `🟢` idle
  - `🟠` processing
- Menu settings:
  - choose working folder
  - reset working folder
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

## Homebrew install

This repo includes a formula at `Formula/screenshot-describer.rb`.

Typical flow (from your tap repo):

```bash
brew tap avchaykin/tap
brew install screenshot-describer
brew services start screenshot-describer
```

Then grant notification permissions to the app when macOS asks.

## Notes

Current processing is a placeholder simulation (1.5s per file). Real screenshot description logic can be plugged into `processQueueIfNeeded()` in `screenshot_describer.swift`.
