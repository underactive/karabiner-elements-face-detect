# Karabiner-Elements Face Detect

Switches Karabiner-Elements profiles based on face presence and built-in keyboard/trackpad activity. Uses the FaceTime camera + Apple Vision framework.

## Privacy

No photos, images, or pixel data are ever saved — to disk, iCloud, or anywhere else. Each poll captures one frame into RAM, passes it to Apple's on-device Vision framework (no network calls), and immediately frees the buffer. The only result that leaves the pipeline is a `Bool`. The daemon writes nothing except log lines to `~/Library/Logs/`.

## Why a bare CLI binary cannot get camera access (TCC)

macOS requires any process accessing the camera to be packaged in an App Bundle whose `Info.plist` declares `NSCameraUsageDescription`. A bare executable has no bundle, so TCC never shows a permission dialog — camera calls are silently denied. LaunchAgents have no `Info.plist` support of their own.

## Workaround: thin app bundle wrapper

**1.** Create the bundle skeleton:
```sh
mkdir -p ~/.local/Applications/FaceProfileDaemon.app/Contents/MacOS
cp ~/.local/bin/face-profile-daemon \
   ~/.local/Applications/FaceProfileDaemon.app/Contents/MacOS/
```

**2.** Write `Info.plist`:
```sh
cat > ~/.local/Applications/FaceProfileDaemon.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.user.face-profile-daemon</string>
  <key>NSCameraUsageDescription</key>
  <string>Detects face presence to switch Karabiner-Elements profiles.</string>
</dict></plist>
EOF
```

**3.** Launch once to trigger the TCC dialog, then approve it:
```sh
open ~/.local/Applications/FaceProfileDaemon.app
```

**4.** Update `com.user.face-profile-daemon.plist` (or re-run `make install` after editing `BIN_DST` in the Makefile) so `ProgramArguments` points to:
```
~/.local/Applications/FaceProfileDaemon.app/Contents/MacOS/face-profile-daemon
```

## Prerequisites

1. **macOS 12+** — required for Swift Concurrency (`async`/`await`).
2. **Karabiner-Elements** installed and running.
3. **Two Karabiner-Elements profiles** named exactly:
   - `⌨️` — active when a face is detected (normal typing)
   - `👻` — active when no face is detected for ≥ 120 s

   Create them in *Karabiner-Elements → Profiles* before running the daemon. The names are case-sensitive and must include the emoji — no quotes, no extra whitespace.

   If the profiles are missing or misnamed, `karabiner_cli` will exit non-zero. The log will show `[FPD] karabiner_cli exit N for '...'` and the daemon will silently retry on the next poll cycle.

## Install

```sh
make install
```

Compiles the binary, installs the plist, and starts the LaunchAgent.

**IMPORTANT:** On modern macOS, the daemon will silently fail to access the camera after running `make install`. You **must** complete the steps in the [Workaround: thin app bundle wrapper](#workaround-thin-app-bundle-wrapper) section above for the daemon to function.

## Verify

```sh
launchctl list | grep face-profile-daemon   # PID column should be non-zero
```

## Logs

The daemon uses Apple's unified logging system (`os.Logger`). Log output is **not** written to plain text files — use the `log` tool to read it.

**Stream live output** (shows new entries as they arrive):
```sh
log stream --predicate 'subsystem == "com.user.face-profile-daemon"' --level debug
```

**Query past entries** (e.g. last hour):
```sh
log show --predicate 'subsystem == "com.user.face-profile-daemon"' --last 1h --level debug
```

Omit `--level debug` to suppress debug-level noise and see only info/error entries.

> `make logs` tails the LaunchAgent stdout/stderr files in `~/Library/Logs/` — those will be empty because `os.Logger` bypasses file descriptors entirely.

## Stop / uninstall

```sh
make uninstall
```
