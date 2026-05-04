REPO       := $(shell pwd)
HOOK       := $(REPO)/hooks/factory-event-bridge.sh
SETTINGS   := $(HOME)/.factory/settings.json
APP_NAME   := DroidMenuBar
BIN_DEBUG  := $(REPO)/.build/debug/DroidMenuBar
BIN_REL    := $(REPO)/.build/release/DroidMenuBar

.PHONY: build run release run-release stop install-hooks uninstall-hooks logs tail-events test-event clean help

help:
	@echo "Targets:"
	@echo "  build              swift build (debug)"
	@echo "  release            swift build -c release"
	@echo "  run                build and run the menu bar app (debug)"
	@echo "  run-release        build (release) and run the menu bar app"
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

stop:
	@pkill -x DroidMenuBar 2>/dev/null || true
	@echo "Stopped any running DroidMenuBar processes."

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
	  install_hook("SessionStart") \
	  | install_hook("SessionEnd") \
	  | install_hook("Notification") \
	  | install_hook("Stop") \
	  | install_hook("UserPromptSubmit") \
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
