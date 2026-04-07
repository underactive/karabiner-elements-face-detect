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

## Install

```sh
make install
```

Compiles the binary, installs the plist, and starts the LaunchAgent.

## Verify

```sh
launchctl list | grep face-profile-daemon   # PID column should be non-zero
make logs                                   # stream live log output
```

## Stop / uninstall

```sh
make uninstall
```
