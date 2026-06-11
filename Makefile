REPO       := $(shell pwd)
COMMON_HOOK := $(REPO)/hooks/agent-event-bridge.sh
FACTORY_HOOK := $(REPO)/hooks/factory-event-bridge.sh
CODEX_HOOK := $(REPO)/hooks/codex-event-bridge.sh
CURSOR_HOOK := $(REPO)/hooks/cursor-event-bridge.sh
CLAUDE_HOOK := $(REPO)/hooks/claude-code-event-bridge.sh
FACTORY_SETTINGS := $(HOME)/.factory/settings.json
CODEX_SETTINGS := $(HOME)/.codex/hooks.json
CURSOR_SETTINGS := $(HOME)/.cursor/hooks.json
CLAUDE_SETTINGS := $(HOME)/.claude/settings.json
APP_NAME   := AgentMenuBar
BIN_DEBUG  := $(REPO)/.build/debug/AgentMenuBar
BIN_REL    := $(REPO)/.build/release/AgentMenuBar
APP_BUNDLE := $(REPO)/build/$(APP_NAME).app
APP_PLIST  := $(REPO)/Resources/Info.plist
INSTALL_DIR := /Applications
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME).app

.PHONY: build run release run-release bundle run-bundle stop install uninstall install-hooks uninstall-hooks install-factory-hooks uninstall-factory-hooks install-codex-hooks uninstall-codex-hooks install-cursor-hooks uninstall-cursor-hooks install-claude-hooks uninstall-claude-hooks logs tail-events test test-event clean help

help:
	@echo "Targets:"
	@echo "  build              swift build (debug)"
	@echo "  release            swift build -c release"
	@echo "  run                build and run the menu bar app (debug)"
	@echo "  run-release        build (release) and run raw binary  [DEPRECATED on macOS 26+ — use run-bundle]"
	@echo "  bundle             package release binary as $(APP_NAME).app with Info.plist (LSUIElement=YES)"
	@echo "  run-bundle         build the .app bundle and launch it via 'open'"
	@echo "  install            copy $(APP_NAME).app into /Applications and launch it"
	@echo "  uninstall          remove $(APP_NAME).app from /Applications"
	@echo "  stop               kill any running $(APP_NAME) process"
	@echo "  install-hooks      add Factory + Codex + Claude Code bridges (additive, idempotent)"
	@echo "  uninstall-hooks    remove Factory + Codex + Claude Code bridges"
	@echo "  install-factory-hooks / uninstall-factory-hooks"
	@echo "  install-codex-hooks / uninstall-codex-hooks"
	@echo "  install-claude-hooks / uninstall-claude-hooks  (Claude Code CLI; ~/.claude/settings.json)"
	@echo "  install-cursor-hooks / uninstall-cursor-hooks  (cursor-agent CLI; shares ~/.cursor/hooks.json with the IDE)"
	@echo "  test               run the unit test suite (swift test)"
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
	@pgrep -fl $(APP_NAME) || echo "(failed to launch — check Console.app)"

stop:
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@echo "Stopped any running $(APP_NAME) processes."

install: stop bundle
	@rm -rf "$(INSTALLED_APP)"
	@cp -R "$(APP_BUNDLE)" "$(INSTALLED_APP)"
	@echo "Installed $(INSTALLED_APP)"
	@open "$(INSTALLED_APP)"
	@sleep 1
	@pgrep -fl $(APP_NAME) || echo "(failed to launch — check Console.app)"
	@echo ""
	@echo "Tip: open System Settings > General > Login Items & Extensions"
	@echo "     and add $(APP_NAME) to launch it automatically at login."

uninstall: stop
	@rm -rf "$(INSTALLED_APP)"
	@echo "Removed $(INSTALLED_APP)"

install-hooks: install-factory-hooks install-codex-hooks install-claude-hooks

uninstall-hooks: uninstall-factory-hooks uninstall-codex-hooks uninstall-claude-hooks

install-factory-hooks:
	@chmod +x "$(COMMON_HOOK)" "$(FACTORY_HOOK)"
	@mkdir -p "$(dir $(FACTORY_SETTINGS))"
	@if [ ! -f "$(FACTORY_SETTINGS)" ]; then echo "{}" > "$(FACTORY_SETTINGS)"; fi
	@cp "$(FACTORY_SETTINGS)" "$(FACTORY_SETTINGS).bak.$$(date +%s)"
	@jq --arg cmd "$(FACTORY_HOOK)" '\
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
	' "$(FACTORY_SETTINGS)" > "$(FACTORY_SETTINGS).new"
	@mv "$(FACTORY_SETTINGS).new" "$(FACTORY_SETTINGS)"
	@echo "Factory hooks installed. Backup: $(FACTORY_SETTINGS).bak.<ts>"
	@echo "Bridge:   $(FACTORY_HOOK)"

uninstall-factory-hooks:
	@if [ ! -f "$(FACTORY_SETTINGS)" ]; then \
	  echo "Nothing to do — $(FACTORY_SETTINGS) not present."; exit 0; \
	fi
	@cp "$(FACTORY_SETTINGS)" "$(FACTORY_SETTINGS).bak.$$(date +%s)"
	@jq --arg cmd "$(FACTORY_HOOK)" '\
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
	' "$(FACTORY_SETTINGS)" > "$(FACTORY_SETTINGS).new"
	@mv "$(FACTORY_SETTINGS).new" "$(FACTORY_SETTINGS)"
	@echo "Factory hooks removed. Backup: $(FACTORY_SETTINGS).bak.<ts>"

install-codex-hooks:
	@chmod +x "$(COMMON_HOOK)" "$(CODEX_HOOK)"
	@mkdir -p "$(dir $(CODEX_SETTINGS))"
	@if [ ! -f "$(CODEX_SETTINGS)" ]; then echo "{}" > "$(CODEX_SETTINGS)"; fi
	@cp "$(CODEX_SETTINGS)" "$(CODEX_SETTINGS).bak.$$(date +%s)"
	@jq --arg cmd "$(CODEX_HOOK)" '\
	  def hook_entry($$m): \
	    ({hooks: [{type: "command", command: $$cmd, timeout: 5, statusMessage: "Updating AgentMenuBar"}]} \
	      + (if $$m == "" then {} else {matcher: $$m} end)); \
	  def install_hook($$e; $$m): \
	    .hooks = (.hooks // {}) | \
	    .hooks[$$e] = ( \
	      ((.hooks[$$e] // []) \
	        | map(.hooks |= map(select(.command != $$cmd))) \
	        | map(select((.hooks // []) | length > 0))) \
	      + [hook_entry($$m)] \
	    ); \
	  install_hook("SessionStart"; "") \
	  | install_hook("UserPromptSubmit"; "") \
	  | install_hook("Notification"; "") \
	  | install_hook("PermissionRequest"; "*") \
	  | install_hook("PreToolUse"; "request_user_input") \
	  | install_hook("PostToolUse"; "*") \
	  | install_hook("Stop"; "") \
	' "$(CODEX_SETTINGS)" > "$(CODEX_SETTINGS).new"
	@mv "$(CODEX_SETTINGS).new" "$(CODEX_SETTINGS)"
	@echo "Codex hooks installed. Backup: $(CODEX_SETTINGS).bak.<ts>"
	@echo "Bridge:   $(CODEX_HOOK)"
	@echo "Open /hooks in Codex once to review and trust this hook definition."

uninstall-codex-hooks:
	@if [ ! -f "$(CODEX_SETTINGS)" ]; then \
	  echo "Nothing to do — $(CODEX_SETTINGS) not present."; exit 0; \
	fi
	@cp "$(CODEX_SETTINGS)" "$(CODEX_SETTINGS).bak.$$(date +%s)"
	@jq --arg cmd "$(CODEX_HOOK)" '\
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
	  | remove_hook("UserPromptSubmit") \
	  | remove_hook("Notification") \
	  | remove_hook("PermissionRequest") \
	  | remove_hook("PreToolUse") \
	  | remove_hook("PostToolUse") \
	  | remove_hook("Stop") \
	  | if (.hooks // {}) == {} then del(.hooks) else . end \
	' "$(CODEX_SETTINGS)" > "$(CODEX_SETTINGS).new"
	@mv "$(CODEX_SETTINGS).new" "$(CODEX_SETTINGS)"
	@echo "Codex hooks removed. Backup: $(CODEX_SETTINGS).bak.<ts>"

install-cursor-hooks:
	@chmod +x "$(COMMON_HOOK)" "$(CURSOR_HOOK)"
	@mkdir -p "$(dir $(CURSOR_SETTINGS))"
	@if [ ! -f "$(CURSOR_SETTINGS)" ]; then echo '{"version":1}' > "$(CURSOR_SETTINGS)"; fi
	@cp "$(CURSOR_SETTINGS)" "$(CURSOR_SETTINGS).bak.$$(date +%s)"
	@jq --arg cmd "$(CURSOR_HOOK)" '\
	  .version = (.version // 1) \
	  | def install_hook($$e): \
	      .hooks = (.hooks // {}) | \
	      .hooks[$$e] = ( \
	        ((.hooks[$$e] // []) | map(select(.command != $$cmd))) \
	        + [{command: $$cmd, timeout: 5}] \
	      ); \
	  install_hook("sessionStart") \
	  | install_hook("beforeSubmitPrompt") \
	  | install_hook("beforeShellExecution") \
	  | install_hook("afterShellExecution") \
	  | install_hook("beforeMCPExecution") \
	  | install_hook("afterMCPExecution") \
	  | install_hook("afterFileEdit") \
	  | install_hook("postToolUse") \
	  | install_hook("stop") \
	  | install_hook("sessionEnd") \
	' "$(CURSOR_SETTINGS)" > "$(CURSOR_SETTINGS).new"
	@mv "$(CURSOR_SETTINGS).new" "$(CURSOR_SETTINGS)"
	@echo "Cursor hooks installed. Backup: $(CURSOR_SETTINGS).bak.<ts>"
	@echo "Bridge:   $(CURSOR_HOOK)"
	@echo "Note: ~/.cursor/hooks.json is shared with the Cursor IDE, so these hooks fire for IDE agent sessions too."
	@echo "Cursor watches hooks.json and reloads it automatically; restart any in-flight cursor-agent session to pick them up."

uninstall-cursor-hooks:
	@if [ ! -f "$(CURSOR_SETTINGS)" ]; then \
	  echo "Nothing to do — $(CURSOR_SETTINGS) not present."; exit 0; \
	fi
	@cp "$(CURSOR_SETTINGS)" "$(CURSOR_SETTINGS).bak.$$(date +%s)"
	@jq --arg cmd "$(CURSOR_HOOK)" '\
	  def remove_hook($$e): \
	    if (.hooks // {}) | has($$e) | not then . else \
	      .hooks[$$e] = ((.hooks[$$e] // []) | map(select(.command != $$cmd))) \
	      | if (.hooks[$$e] | length) == 0 then del(.hooks[$$e]) else . end \
	    end; \
	  remove_hook("sessionStart") \
	  | remove_hook("beforeSubmitPrompt") \
	  | remove_hook("beforeShellExecution") \
	  | remove_hook("afterShellExecution") \
	  | remove_hook("beforeMCPExecution") \
	  | remove_hook("afterMCPExecution") \
	  | remove_hook("afterFileEdit") \
	  | remove_hook("postToolUse") \
	  | remove_hook("stop") \
	  | remove_hook("sessionEnd") \
	  | if (.hooks // {}) == {} then del(.hooks) else . end \
	' "$(CURSOR_SETTINGS)" > "$(CURSOR_SETTINGS).new"
	@mv "$(CURSOR_SETTINGS).new" "$(CURSOR_SETTINGS)"
	@echo "Cursor hooks removed. Backup: $(CURSOR_SETTINGS).bak.<ts>"

install-claude-hooks:
	@chmod +x "$(COMMON_HOOK)" "$(CLAUDE_HOOK)"
	@mkdir -p "$(dir $(CLAUDE_SETTINGS))"
	@if [ ! -f "$(CLAUDE_SETTINGS)" ]; then echo "{}" > "$(CLAUDE_SETTINGS)"; fi
	@cp "$(CLAUDE_SETTINGS)" "$(CLAUDE_SETTINGS).bak.$$(date +%s)"
	@jq --arg cmd "$(CLAUDE_HOOK)" '\
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
	  | install_hook("UserPromptSubmit") \
	  | install_matcher_hook("Notification"; "permission_prompt|elicitation_dialog") \
	  | install_hook("PermissionRequest") \
	  | install_hook("PostToolUse") \
	  | install_hook("Stop") \
	  | install_hook("SessionEnd") \
	' "$(CLAUDE_SETTINGS)" > "$(CLAUDE_SETTINGS).new"
	@mv "$(CLAUDE_SETTINGS).new" "$(CLAUDE_SETTINGS)"
	@echo "Claude Code hooks installed. Backup: $(CLAUDE_SETTINGS).bak.<ts>"
	@echo "Bridge:   $(CLAUDE_HOOK)"
	@echo "Restart any in-flight Claude Code session to pick up the new hooks (use /hooks to verify)."

uninstall-claude-hooks:
	@if [ ! -f "$(CLAUDE_SETTINGS)" ]; then \
	  echo "Nothing to do — $(CLAUDE_SETTINGS) not present."; exit 0; \
	fi
	@cp "$(CLAUDE_SETTINGS)" "$(CLAUDE_SETTINGS).bak.$$(date +%s)"
	@jq --arg cmd "$(CLAUDE_HOOK)" '\
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
	  | remove_hook("UserPromptSubmit") \
	  | remove_hook("Notification") \
	  | remove_hook("PermissionRequest") \
	  | remove_hook("PostToolUse") \
	  | remove_hook("Stop") \
	  | remove_hook("SessionEnd") \
	  | if (.hooks // {}) == {} then del(.hooks) else . end \
	' "$(CLAUDE_SETTINGS)" > "$(CLAUDE_SETTINGS).new"
	@mv "$(CLAUDE_SETTINGS).new" "$(CLAUDE_SETTINGS)"
	@echo "Claude Code hooks removed. Backup: $(CLAUDE_SETTINGS).bak.<ts>"

test:
	swift test

test-event:
	@$(REPO)/scripts/send-test-event.sh

tail-events logs:
	@mkdir -p "$(HOME)/Library/Logs/$(APP_NAME)"
	@touch "$(HOME)/Library/Logs/$(APP_NAME)/events.log"
	@tail -f "$(HOME)/Library/Logs/$(APP_NAME)/events.log"

clean:
	swift package clean
