#
# NoLid
#
# `make install` builds both binaries and replaces both, always together.
#
# That pairing is the whole reason this file exists. The app and the `nolid`
# CLI talk over a shared control channel, and its shape can change between
# versions. Upgrade one and leave the other, and the CLI reports "NoLid is not
# answering" while the app is plainly running — which silently disables
# `nolid status` and the checks the other commands make before they act. It is
# a confusing failure to be in and an easy one to fall into, so this file does
# not offer the half that causes it.
#
# The default PREFIX needs no sudo. Installing the app as root would leave it
# running as root, which is worse than anything it buys.
#

PREFIX  ?= $(HOME)/.local
APP_DIR ?= /Applications

BIN_DIR := $(PREFIX)/bin
APP     := $(APP_DIR)/NoLid.app
CLI     := $(BIN_DIR)/nolid

.DEFAULT_GOAL := help
.PHONY: help build test install uninstall clean run doctor

help:
	@echo "NoLid"
	@echo
	@echo "  make install     Build and install the app and the CLI, together"
	@echo "  make uninstall   Remove both, and the saved preferences"
	@echo "  make build       Build into ./build, install nothing"
	@echo "  make test        Run the test suite"
	@echo "  make doctor      Ask the installed CLI what this Mac supports"
	@echo "  make run         Build and launch from ./build, without installing"
	@echo "  make clean       Delete ./build"
	@echo
	@echo "  PREFIX=$(PREFIX)"
	@echo "  APP_DIR=$(APP_DIR)"
	@echo
	@echo "Installs somewhere else with e.g. PREFIX=/usr/local (needs sudo for"
	@echo "the CLI alone: run 'make build', then copy build/nolid by hand)."

build:
	@./build.sh

test:
	@./test.sh

# The app and the CLI are installed in one step, on purpose. See the header.
install: build
	@echo "==> Stopping NoLid, if it is running"
	@osascript -e 'tell application "NoLid" to quit' 2>/dev/null || true
	@sleep 2
	@pkill -TERM -f "$(APP)/Contents/MacOS/NoLid" 2>/dev/null || true
	@mkdir -p "$(BIN_DIR)"
	@echo "==> Installing $(APP)"
	@rm -rf "$(APP)"
	@cp -R build/NoLid.app "$(APP)"
	@echo "==> Installing $(CLI)"
	@cp -f build/nolid "$(CLI)"
	@codesign --verify --deep --strict "$(APP)" \
		|| { echo "    signature check failed; not launching"; exit 1; }
	@echo "==> Launching"
	@open "$(APP)"
	@sleep 3
	@# The app answering its own CLI is the one check worth making here: it
	@# proves the pair actually agrees, which is the failure this file exists
	@# to prevent. A version mismatch looks exactly like a crashed app.
	@"$(CLI)" status >/dev/null 2>&1 \
		&& echo "==> Installed. The app and the CLI agree." \
		|| { echo "==> Installed, but the CLI got no answer from the app."; \
		     echo "    Check the menu bar; run '$(CLI) doctor' for detail."; exit 1; }
	@case ":$(PATH):" in *":$(BIN_DIR):"*) ;; \
		*) echo "    Note: $(BIN_DIR) is not on your PATH." ;; esac
	@echo "    Ad-hoc signing changes the binary on every build, so re-enable"
	@echo "    'Launch at login' from the menu after each install."

uninstall:
	@echo "==> Stopping NoLid, if it is running"
	@osascript -e 'tell application "NoLid" to quit' 2>/dev/null || true
	@sleep 2
	@pkill -TERM -f "$(APP)/Contents/MacOS/NoLid" 2>/dev/null || true
	@rm -rf "$(APP)"
	@rm -f "$(CLI)"
	@defaults delete dev.nolid.app 2>/dev/null || true
	@echo "==> Removed. Turn off 'Launch at login' if it is still listed in"
	@echo "    System Settings > General > Login Items."

doctor:
	@"$(CLI)" doctor

run: build
	@open build/NoLid.app

clean:
	@rm -rf build
