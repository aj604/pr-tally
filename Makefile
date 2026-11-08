# Thin wrapper around SwiftPM and scripts/. Run `make help` for targets.

# The Command Line Tools can't build SwiftUI on macOS 27+, so use Xcode when
# it's installed but not selected (same rule as scripts/bundle.sh).
ifeq ($(origin DEVELOPER_DIR),undefined)
  ifneq ($(findstring CommandLineTools,$(shell xcode-select -p)),)
    XCODE := $(shell mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" | head -n 1)
    ifneq ($(XCODE),)
      export DEVELOPER_DIR := $(XCODE)/Contents/Developer
    endif
  endif
endif

SNAPSHOT_OUT ?= out.png
MODE ?=

.DEFAULT_GOAL := help
.PHONY: help build test test-no-keychain bundle install snapshot clean

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

build: ## Debug build
	swift build

test: ## Run all tests
	swift test

test-no-keychain: ## Run tests, skipping KeychainTokenTests
	swift test --skip KeychainTokenTests

bundle: ## Build dist/PR Tally.app
	./scripts/bundle.sh

install: ## Build, install to ~/Applications, and launch
	./scripts/install.sh

snapshot: ## Render popover: make snapshot [SNAPSHOT_OUT=out.png] [MODE=dark|rollover|overview|drilldown|menubar|milestone]
	swift run PopoverSnapshot $(SNAPSHOT_OUT) $(MODE)

clean: ## Remove build output
	swift package clean
	rm -rf dist
