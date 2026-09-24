# Path to the Xcode.app bundle the build uses (see nix/overlays/xcode.nix).
# Example: make XCODE_PATH=/Applications/Xcode.app
XCODE_PATH ?=

# Release tag, e.g. v0.41.0-plynic.3. If not set, .nix/config/version.txt
# ("develop") is used.
VERSION ?=

# Flake output attribute to build. If not set, the default package (all
# release files) is built.
TARGET ?=

# Extra arguments for nix build, e.g.
#   NIX_ARGS='--override-input plynic-mpv git+file:///path/to/plynic-mpv?rev=<sha>'
NIX_ARGS ?=

all: build

# Build with Nix flakes, then copy the result to dist/ and write
# dist/manifest.json (not for a TARGET build).
# .nix/config/xcode.path and .nix/config/version.txt are restored to their
# committed values afterwards.
.PHONY: build
build:
	trap 'git checkout -- .nix/config/xcode.path .nix/config/version.txt' EXIT; \
	$(if $(XCODE_PATH),echo '$(XCODE_PATH)' > .nix/config/xcode.path;,) \
	$(if $(VERSION),echo '$(VERSION)' > .nix/config/version.txt;,) \
	nix build -v -L \
		--option sandbox true \
		--option sandbox-fallback false \
		$(if $(XCODE_PATH),--option extra-sandbox-paths $(XCODE_PATH),) \
		$(NIX_ARGS) \
		$(if $(TARGET),.#$(TARGET),) && \
	$(if $(TARGET),true,$(MAKE) dist)

# dist/: the release files, plus manifest.json
.PHONY: dist
dist:
	rm -rf dist
	cp -RL result dist
	chmod -R u+w dist
	python3 tools/manifest.py dist \
		--tag "$$(cat .nix/config/version.txt)" \
		--xcode "$(if $(XCODE_PATH),$(XCODE_PATH),/Applications/Xcode.app)"
