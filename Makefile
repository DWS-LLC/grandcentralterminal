# Grand Central Terminal — build, sign, install.
#
#   make build      libghostty (if stale) + swift release + app bundle +
#                   staged support copy (daemon, helper, agent skill)
#   make notarize   build + sign + submit + staple (needs Apple creds)
#   make install    everything above + /Applications +
#                   /usr/local/bin/gctd symlink + harness skill install
#   make uninstall  remove /Applications copy + symlink
#                   (keeps pane state, skills, config)
#   make clean      drop build artifacts (not vendor/, not user state)
#
# Config: ZIG=, SIGN_IDENTITY=, NOTARY_PROFILE= (notarytool keychain
# profile), DESTDIR= (staged installs, default /).

APP_NAME := Grand Central Terminal
BUILD_DIR := build
SWIFT_BUILD := .build/release
BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
SUPPORT := $(HOME)/Library/Application Support/Grand Central Terminal
DESTDIR :=
ZIG ?= /tmp/zig0160/zig
SIGN_IDENTITY ?= Developer ID Application: Tanishq Dubey (P3FJ87836G)
NOTARY_PROFILE ?= gct
LIBGHOSTTY_A := vendor/ghostty/macos/build/ReleaseLocal/libghostty-internal.a

.PHONY: build sign notarize install uninstall clean

build:
	@if [ ! -f "$(LIBGHOSTTY_A)" ] || [ -n "$$(find patches vendor/ghostty/include/ghostty.h -newer "$(LIBGHOSTTY_A)" 2>/dev/null | head -1)" ]; then \
		echo "== building libghostty =="; \
		(cd vendor/ghostty && PATH="$$(dirname "$(ZIG)"):$$PATH" \
			zig build -Demit-xcframework=true -Dxcframework-target=native \
			-Doptimize=ReleaseFast > /tmp/gbuild.log 2>&1) || { \
			grep -m1 -B2 -A8 "error:" /tmp/gbuild.log; exit 1; }; \
	fi
	mkdir -p lib Sources/CGhostty
	cp "$(LIBGHOSTTY_A)" lib/libghostty.a
	cp vendor/ghostty/include/ghostty.h Sources/CGhostty/ghostty.h
	@echo "== swift build =="
	swift build -c release
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	cp Resources/Info.plist "$(BUNDLE)/Contents/Info.plist"
	cp "$(SWIFT_BUILD)/GrandCentralTerminal" "$(BUNDLE)/Contents/MacOS/"
	cp "$(SWIFT_BUILD)/gctd" "$(BUNDLE)/Contents/MacOS/"
	cp "$(SWIFT_BUILD)/ptyexec" "$(BUNDLE)/Contents/MacOS/"
	cp Resources/AppIcon.icns "$(BUNDLE)/Contents/Resources/"
	mkdir -p "$(SUPPORT)/bin" "$(SUPPORT)/skills/gct"
	# Rename-swap, never overwrite in place: the daemon executes from this
	# path, and an in-place rewrite of a running image invalidates its code
	# signature (macOS then SIGKILLs every new exec — including the Claude
	# SessionStart hook).
	cp "$(SWIFT_BUILD)/gctd" "$(SUPPORT)/bin/gctd.new"
	mv -f "$(SUPPORT)/bin/gctd.new" "$(SUPPORT)/bin/gctd"
	cp "$(SWIFT_BUILD)/ptyexec" "$(SUPPORT)/bin/ptyexec.new"
	mv -f "$(SUPPORT)/bin/ptyexec.new" "$(SUPPORT)/bin/ptyexec"
	cp SKILL.md "$(SUPPORT)/skills/gct/SKILL.md"
	@echo "built $(BUNDLE) (daemon staged in $(SUPPORT)/bin)"

# Developer ID + hardened runtime. Inner binaries first, bundle last
# (--deep avoided: explicit order, no surprises). Verifies after.
sign: build
	codesign --force --options runtime --timestamp \
		--sign "$(SIGN_IDENTITY)" \
		"$(BUNDLE)/Contents/MacOS/GrandCentralTerminal" \
		"$(BUNDLE)/Contents/MacOS/gctd" \
		"$(BUNDLE)/Contents/MacOS/ptyexec"
	codesign --force --options runtime --timestamp \
		--sign "$(SIGN_IDENTITY)" "$(BUNDLE)"
	codesign --verify --strict --verbose=2 "$(BUNDLE)"
	@echo "signed $(BUNDLE)"

# Notarize + staple: zip (keeps the ticket queryable), submit with the
# keychain profile, wait, staple the ticket back onto the bundle.
# Stapled ticket = Gatekeeper passes offline.
notarize: sign
	/usr/bin/ditto -c -k --keepParent "$(BUNDLE)" "$(BUILD_DIR)/notarize.zip"
	xcrun notarytool submit "$(BUILD_DIR)/notarize.zip" \
		--keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(BUNDLE)"
	xcrun stapler validate "$(BUNDLE)"
	rm -f "$(BUILD_DIR)/notarize.zip"
	@echo "notarized + stapled $(BUNDLE)"

# Best-effort quit first: replacing the bundle under a running app and
# the staged daemon under a running daemon just re-creates the old
# binary-skew (CLI newer than daemon). Panes die with the daemon.
install: notarize
	pkill -x GrandCentralTerminal 2>/dev/null || true
	"$(SUPPORT)/bin/gctd" stop 2>/dev/null || true
	sudo rm -rf "$(DESTDIR)/Applications/$(APP_NAME).app"
	sudo cp -R "$(BUNDLE)" "$(DESTDIR)/Applications/$(APP_NAME).app"
	sudo ln -sf "$(SUPPORT)/bin/gctd" "$(DESTDIR)/usr/local/bin/gctd"
	"$(SUPPORT)/bin/gctd" agent-setup install --hooks --yes
	@echo "installed /Applications/$(APP_NAME).app + /usr/local/bin/gctd"

uninstall:
	sudo rm -rf "$(DESTDIR)/Applications/$(APP_NAME).app"
	sudo rm -f "$(DESTDIR)/usr/local/bin/gctd"
	@echo "removed. Pane state/config/skills kept;"
	@echo "  skills: gctd agent-setup uninstall"

clean:
	rm -rf "$(BUILD_DIR)" .build
	rm -f lib/libghostty.a Sources/CGhostty/ghostty.h
	@echo "clean (vendor/ and user state kept)"
