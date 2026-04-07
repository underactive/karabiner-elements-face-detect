SHELL    = /bin/sh
LABEL    = com.user.face-profile-daemon
BIN      = face-profile-daemon
BIN_DST  = $(HOME)/.local/bin/$(BIN)
PLIST_DST = $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG_OUT  = $(HOME)/Library/Logs/$(BIN).out.log
LOG_ERR  = $(HOME)/Library/Logs/$(BIN).err.log

.PHONY: compile install uninstall logs

## Build the binary from FaceProfileDaemon.swift, which embeds FacePresenceDetector
## inline so it is self-contained (also runnable as: swift FaceProfileDaemon.swift).
compile: FaceProfileDaemon.swift
	swiftc -O FaceProfileDaemon.swift -o $(BIN)

## Compile, install binary + plist, start the LaunchAgent.
## Camera TCC permission must be granted separately — see README.txt.
install: compile
	mkdir -p "$(HOME)/.local/bin"
	mkdir -p "$(HOME)/Library/LaunchAgents"
	mkdir -p "$(HOME)/Library/Logs"
	cp "$(BIN)" "$(BIN_DST)"
	sed "s|__HOME__|$(HOME)|g" "$(LABEL).plist" > "$(PLIST_DST)"
	launchctl bootstrap "gui/$$(id -u)" "$(PLIST_DST)"
	@echo ""
	@echo "Installed $(BIN)."
	@echo "IMPORTANT: camera TCC permission is required — see README.txt."

## Stop the LaunchAgent and remove all installed files.
uninstall:
	-launchctl bootout "gui/$$(id -u)" "$(PLIST_DST)" 2>/dev/null
	rm -f "$(PLIST_DST)" "$(BIN_DST)"
	@echo "Uninstalled $(BIN)."

## Stream both log files (Ctrl-C to exit).
logs:
	tail -f "$(LOG_OUT)" "$(LOG_ERR)"
