# Covey.app bundle targets. Day-to-day SPM loop stays `swift build` / `swift test`.
#
#   make app      — build Release Covey.app (regenerates .xcodeproj if project.yml changed)
#   make install  — app + replace /Applications/Covey.app
#   make icons    — re-slice App icon from icon.png (runs automatically when icon.png changes)
#
# Dev instance — debug binaries against an isolated state root (own socket,
# own daemon, own sessions; the prod install and its daemon stay untouched):
#
#   make dev         — build & launch the dev GUI; restarts a stale dev daemon
#                      so what you test is always the fresh binary
#   make dev-status  — dev GUI / dev daemon: running or not, pids, strays
#   make dev-stop    — TERM both, wait for exit (no orphaned coveyd)
#   make dev-clean   — dev-stop + wipe the sandbox
#
# SIGN: ad-hoc until an Apple ID team is configured in project.yml — then drop it.

DERIVED := .build/xcode
APP     := $(DERIVED)/Build/Products/Release/Covey.app
ICONSET := App/Assets.xcassets/AppIcon.appiconset
SIGN    := CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES
# XcodeGen bakes the file list into the project: adding, removing or renaming
# a source file bumps its directory's mtime, which must regenerate it too.
SRC_DIRS := $(shell find Sources/covey Sources/coveyd App/Assets.xcassets -type d)

DEV_HOME   := $(CURDIR)/.devhome
DEV_STATE  := $(DEV_HOME)/.covey
DEV_GUI    := $(CURDIR)/.build/debug/covey
DEV_GUI_PIDFILE    := $(DEV_HOME)/gui.pid
DEV_DAEMON_PIDFILE := $(DEV_STATE)/coveyd.pid
DEV_LOG    := $(DEV_HOME)/gui.log

.PHONY: app install icons dev dev-status dev-stop dev-clean

Covey.xcodeproj/project.pbxproj: project.yml $(SRC_DIRS)
	xcodegen generate
	touch $@

# Stamp: any slice regenerated after icon.png means the whole set is fresh.
$(ICONSET)/icon_512@2x.png: icon.png
	for size in 16 32 128 256 512; do \
		sips -z $$size $$size icon.png --out "$(ICONSET)/icon_$$size.png" >/dev/null; \
		sips -z $$((size * 2)) $$((size * 2)) icon.png --out "$(ICONSET)/icon_$$size@2x.png" >/dev/null; \
	done

icons: $(ICONSET)/icon_512@2x.png

app: Covey.xcodeproj/project.pbxproj icons
	xcodebuild -project Covey.xcodeproj -scheme Covey -configuration Release \
		-derivedDataPath $(DERIVED) build $(SIGN)

install: app
	rm -rf /Applications/Covey.app
	ditto "$(APP)" /Applications/Covey.app
	@echo "Installed /Applications/Covey.app"

# ── Dev instance ────────────────────────────────────────────────────────────
# The sandbox lives outside .build on purpose: `swift package clean` must not
# orphan a running daemon by deleting its pidfile.

dev:
	@mkdir -p "$(DEV_HOME)"
	@if [ -f "$(DEV_GUI_PIDFILE)" ] && kill -0 $$(cat "$(DEV_GUI_PIDFILE)") 2>/dev/null; then \
		echo "dev GUI already running (pid $$(cat "$(DEV_GUI_PIDFILE)")) — make dev-stop first"; exit 1; \
	fi
	swift build
	@if [ -f "$(DEV_DAEMON_PIDFILE)" ] && kill -0 $$(cat "$(DEV_DAEMON_PIDFILE)") 2>/dev/null; then \
		dp=$$(cat "$(DEV_DAEMON_PIDFILE)"); \
		echo "restarting stale dev daemon (pid $$dp) so you test fresh binaries"; \
		kill -TERM $$dp; \
		for i in $$(seq 1 15); do kill -0 $$dp 2>/dev/null || break; sleep 0.2; done; \
	fi
	@COVEY_HOME="$(DEV_HOME)" "$(DEV_GUI)" > "$(DEV_LOG)" 2>&1 & echo $$! > "$(DEV_GUI_PIDFILE)"
	@for i in $$(seq 1 25); do [ -S "$(DEV_STATE)/coveyd.sock" ] && break; sleep 0.2; done
	@$(MAKE) --no-print-directory dev-status
	@echo "state: $(DEV_STATE) · log: $(DEV_LOG)"

dev-status:
	@if [ -f "$(DEV_GUI_PIDFILE)" ] && kill -0 $$(cat "$(DEV_GUI_PIDFILE)") 2>/dev/null; then \
		echo "dev GUI:    running (pid $$(cat "$(DEV_GUI_PIDFILE)"))"; \
	else \
		echo "dev GUI:    not running"; \
	fi
	@if [ -S "$(DEV_STATE)/coveyd.sock" ]; then \
		if [ -f "$(DEV_DAEMON_PIDFILE)" ] && kill -0 $$(cat "$(DEV_DAEMON_PIDFILE)") 2>/dev/null; then \
			echo "dev daemon: running (pid $$(cat "$(DEV_DAEMON_PIDFILE)"))"; \
		else \
			echo "dev daemon: socket up but pidfile stale — inspect $(DEV_STATE)"; \
		fi; \
	else \
		echo "dev daemon: not running"; \
	fi
	@strays=""; for p in $$(pgrep -f '$(CURDIR)/\.build/debug/covey(d?)$$' 2>/dev/null); do \
		case " $$([ -f "$(DEV_GUI_PIDFILE)" ] && cat "$(DEV_GUI_PIDFILE)") $$([ -f "$(DEV_DAEMON_PIDFILE)" ] && cat "$(DEV_DAEMON_PIDFILE)") " in \
			*" $$p "*) ;; *) strays="$$strays $$p" ;; esac; done; \
	if [ -n "$$strays" ]; then echo "stray dev processes:$$strays — make dev-stop"; fi

dev-stop:
	@if [ -f "$(DEV_GUI_PIDFILE)" ]; then \
		if kill -0 $$(cat "$(DEV_GUI_PIDFILE)") 2>/dev/null; then \
			kill -TERM $$(cat "$(DEV_GUI_PIDFILE)") && echo "dev GUI: stopped (pid $$(cat "$(DEV_GUI_PIDFILE)"))"; \
		else echo "dev GUI: not running"; fi; \
		rm -f "$(DEV_GUI_PIDFILE)"; \
	fi
	@if [ -f "$(DEV_DAEMON_PIDFILE)" ]; then \
		dp=$$(cat "$(DEV_DAEMON_PIDFILE)"); \
		if kill -0 $$dp 2>/dev/null; then \
			kill -TERM $$dp; \
			for i in $$(seq 1 25); do kill -0 $$dp 2>/dev/null || break; sleep 0.2; done; \
			if kill -0 $$dp 2>/dev/null; then echo "dev daemon: did not exit, KILL $$dp"; kill -9 $$dp; \
			else echo "dev daemon: stopped (pid $$dp)"; fi; \
		else echo "dev daemon: not running"; fi; \
		rm -f "$(DEV_DAEMON_PIDFILE)"; \
	fi
	@if [ -S "$(DEV_STATE)/coveyd.sock" ]; then echo "socket lingered, removed"; rm -f "$(DEV_STATE)/coveyd.sock"; fi
	@strays=$$(pgrep -f '$(CURDIR)/\.build/debug/covey(d?)$$' 2>/dev/null); \
	if [ -n "$$strays" ]; then echo "killing strays: $$strays"; kill -TERM $$strays 2>/dev/null || true; fi
	@echo "dev instance stopped"

dev-clean: dev-stop
	@rm -rf "$(DEV_HOME)"
	@echo "dev sandbox wiped: $(DEV_HOME)"
