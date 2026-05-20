REPO       := $(shell pwd)
HOOK       := $(REPO)/hooks/factory-event-bridge.sh
SETTINGS   := $(HOME)/.factory/settings.json
APP_NAME   := DroidMenuBar
BIN_DEBUG  := $(REPO)/.build/debug/DroidMenuBar
BIN_REL    := $(REPO)/.build/release/DroidMenuBar
APP_BUNDLE := $(REPO)/build/$(APP_NAME).app
APP_PLIST  := $(REPO)/Resources/Info.plist
INSTALL_DIR := /Applications
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME).app

.PHONY: build run release run-release bundle run-bundle stop install uninstall install-hooks uninstall-hooks logs tail-events test-event clean help

help:
	@echo "Targets:"
	@echo "  build              swift build (debug)"
	@echo "  release            swift build -c release"
	@echo "  run                build and run the menu bar app (debug)"
	@echo "  run-release        build (release) and run raw binary  [DEPRECATED on macOS 26+ — use run-bundle]"
	@echo "  bundle             package release binary as DroidMenuBar.app with Info.plist (LSUIElement=YES)"
	@echo "  run-bundle         build the .app bundle and launch it via 'open'"
	@echo "  install            copy DroidMenuBar.app into /Applications and launch it"
	@echo "  uninstall          remove DroidMenuBar.app from /Applications"
	@echo "  stop               kill any running DroidMenuBar process"
	@echo "  install-hooks      add the bridge to ~/.factory/settings.json (additive, idempotent)"
	@echo "  uninstall-hooks    remove the bridge from ~/.factory/settings.json"
	@echo "  test-event         send a fake Notification event to the running app"
	@echo "  tail-events        tail the debug event log"
	@echo "  clean              swift package clean"

build:
	swift build

release:
	swift build -c release

run: build
	@echo "Launching $(APP_NAME) (debug)..."
	@$(BIN_DEBUG) &

run-release: release
	@echo "Launching $(APP_NAME) (release)..."
	@$(BIN_REL) &

bundle: release
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BIN_REL)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp "$(APP_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"
	@printf 'APPL????' > "$(APP_BUNDLE)/Contents/PkgInfo"
	@codesign --force --deep --sign - "$(APP_BUNDLE)" >/dev/null 2>&1 || true
	@echo "Built $(APP_BUNDLE)"

run-bundle: stop bundle
	@echo "Launching $(APP_BUNDLE)..."
	@open "$(APP_BUNDLE)"
	@sleep 1
	@pgrep -fl DroidMenuBar || echo "(failed to launch — check Console.app)"

stop:
	@pkill -x DroidMenuBar 2>/dev/null || true
	@echo "Stopped any running DroidMenuBar processes."

install: stop bundle
	@rm -rf "$(INSTALLED_APP)"
	@cp -R "$(APP_BUNDLE)" "$(INSTALLED_APP)"
	@echo "Installed $(INSTALLED_APP)"
	@open "$(INSTALLED_APP)"
	@sleep 1
	@pgrep -fl DroidMenuBar || echo "(failed to launch — check Console.app)"
	@echo ""
	@echo "Tip: open System Settings > General > Login Items & Extensions"
	@echo "     and add DroidMenuBar to launch it automatically at login."

uninstall: stop
	@rm -rf "$(INSTALLED_APP)"
	@echo "Removed $(INSTALLED_APP)"

install-hooks:
	@chmod +x "$(HOOK)"
	@mkdir -p "$(dir $(SETTINGS))"
	@if [ ! -f "$(SETTINGS)" ]; then echo "{}" > "$(SETTINGS)"; fi
	@cp "$(SETTINGS)" "$(SETTINGS).bak.$$(date +%s)"
	@jq --arg cmd "$(HOOK)" '\
	  def install_hook($$e): \
	    .hooks = (.hooks // {}) | \
	    .hooks[$$e] = ( \
	      ((.hooks[$$e] // []) \
	        | map(.hooks |= map(select(.command != $$cmd))) \
	        | map(select((.hooks // []) | length > 0))) \
	      + [{hooks: [{type: "command", command: $$cmd, timeout: 5}]}] \
	    ); \
	  def install_matcher_hook($$e; $$m): \
	    .hooks = (.hooks // {}) | \
	    .hooks[$$e] = ( \
	      ((.hooks[$$e] // []) \
	        | map(.hooks |= map(select(.command != $$cmd))) \
	        | map(select((.hooks // []) | length > 0))) \
	      + [{matcher: $$m, hooks: [{type: "command", command: $$cmd, timeout: 5}]}] \
	    ); \
	  install_hook("SessionStart") \
	  | install_hook("SessionEnd") \
	  | install_hook("Notification") \
	  | install_hook("Stop") \
	  | install_hook("UserPromptSubmit") \
	  | install_matcher_hook("PreToolUse"; "AskUser") \
	  | install_matcher_hook("PostToolUse"; "AskUser") \
	' "$(SETTINGS)" > "$(SETTINGS).new"
	@mv "$(SETTINGS).new" "$(SETTINGS)"
	@echo "Hooks installed. Backup: $(SETTINGS).bak.<ts>"
	@echo "Bridge:   $(HOOK)"

uninstall-hooks:
	@if [ ! -f "$(SETTINGS)" ]; then \
	  echo "Nothing to do — $(SETTINGS) not present."; exit 0; \
	fi
	@cp "$(SETTINGS)" "$(SETTINGS).bak.$$(date +%s)"
	@jq --arg cmd "$(HOOK)" '\
	  def remove_hook($$e): \
	    if (.hooks // {}) | has($$e) | not then . else \
	      .hooks[$$e] = ( \
	        ((.hooks[$$e] // []) \
	         | map(.hooks |= map(select(.command != $$cmd))) \
	         | map(select((.hooks // []) | length > 0))) \
	      ) \
	      | if (.hooks[$$e] | length) == 0 then del(.hooks[$$e]) else . end \
	    end; \
	  remove_hook("SessionStart") \
	  | remove_hook("SessionEnd") \
	  | remove_hook("Notification") \
	  | remove_hook("Stop") \
	  | remove_hook("UserPromptSubmit") \
	  | remove_hook("PreToolUse") \
	  | remove_hook("PostToolUse") \
	  | if (.hooks // {}) == {} then del(.hooks) else . end \
	' "$(SETTINGS)" > "$(SETTINGS).new"
	@mv "$(SETTINGS).new" "$(SETTINGS)"
	@echo "Hooks removed. Backup: $(SETTINGS).bak.<ts>"

test-event:
	@$(REPO)/scripts/send-test-event.sh

tail-events logs:
	@mkdir -p "$(HOME)/Library/Logs/DroidMenuBar"
	@touch "$(HOME)/Library/Logs/DroidMenuBar/events.log"
	@tail -f "$(HOME)/Library/Logs/DroidMenuBar/events.log"

clean:
	swift package clean
