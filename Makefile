REPO       := $(shell pwd)
HOOK       := $(REPO)/hooks/factory-event-bridge.sh
SETTINGS   := $(HOME)/.factory/settings.json
APP_NAME   := DroidMenuBar

.PHONY: build run debug release install-hooks uninstall-hooks logs tail-events clean help

help:
	@echo "Targets:"
	@echo "  build              swift build (debug)"
	@echo "  release            swift build -c release"
	@echo "  run                build and run the menu bar app"
	@echo "  install-hooks      register hooks/factory-event-bridge.sh in ~/.factory/settings.json"
	@echo "  uninstall-hooks    remove the bridge hooks from ~/.factory/settings.json"
	@echo "  tail-events        tail the debug event log"
	@echo "  logs               same as tail-events"
	@echo "  clean              swift package clean"

build:
	swift build

release:
	swift build -c release

run: build
	@echo "Launching $(APP_NAME)..."
	./.build/debug/DroidMenuBar

install-hooks:
	@chmod +x "$(HOOK)"
	@if [ ! -f "$(SETTINGS)" ]; then \
	  echo "ERROR: $(SETTINGS) not found. Run droid at least once first."; exit 1; \
	fi
	@cp "$(SETTINGS)" "$(SETTINGS).bak.$$(date +%s)"
	@DROID_MENUBAR_HOOK="$(HOOK)" \
	  jq --arg cmd "$(HOOK)" '\
	    .hooks = (.hooks // {}) | \
	    .hooks.SessionStart    = [{hooks:[{type:"command",command:$$cmd,timeout:5}]}] | \
	    .hooks.SessionEnd      = [{hooks:[{type:"command",command:$$cmd,timeout:5}]}] | \
	    .hooks.Notification    = [{hooks:[{type:"command",command:$$cmd,timeout:5}]}] | \
	    .hooks.Stop            = [{hooks:[{type:"command",command:$$cmd,timeout:5}]}] | \
	    .hooks.UserPromptSubmit= [{hooks:[{type:"command",command:$$cmd,timeout:5}]}] \
	  ' "$(SETTINGS)" > "$(SETTINGS).new"
	@mv "$(SETTINGS).new" "$(SETTINGS)"
	@echo "Hooks installed. Backup at $(SETTINGS).bak.<ts>"
	@echo "Bridge: $(HOOK)"

uninstall-hooks:
	@if [ ! -f "$(SETTINGS)" ]; then \
	  echo "Nothing to do — $(SETTINGS) not present."; exit 0; \
	fi
	@cp "$(SETTINGS)" "$(SETTINGS).bak.$$(date +%s)"
	@jq --arg cmd "$(HOOK)" '\
	  if (.hooks // {}) == {} then . else \
	    .hooks |= ( \
	      to_entries \
	      | map(.value |= map(.hooks |= map(select(.command != $$cmd)))) \
	      | map(.value |= map(select((.hooks // []) | length > 0))) \
	      | map(select((.value // []) | length > 0)) \
	      | from_entries \
	    ) end \
	  ' "$(SETTINGS)" > "$(SETTINGS).new"
	@mv "$(SETTINGS).new" "$(SETTINGS)"
	@echo "Hooks removed."

tail-events logs:
	@touch "$(HOME)/Library/Logs/DroidMenuBar/events.log"
	@tail -f "$(HOME)/Library/Logs/DroidMenuBar/events.log"

clean:
	swift package clean
