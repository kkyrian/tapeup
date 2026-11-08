.PHONY: verify-fast verify-full uitest uitest-agents bundle install release test

verify-fast:
	python3 scripts/agent-workspace/install-hooks.py --check
	swift format lint --strict -r Sources Tests Package.swift
	swift build
	swift test

verify-full: verify-fast
	scripts/bundle.sh release
	mise exec -- osv-scanner scan source --allow-no-lockfiles .

# Drives the real panel through every flow on this Mac, recording a few
# seconds for real; pictures of each step land in tmp/uitest.
uitest:
	scripts/bundle.sh
	.build/TapeUp.app/Contents/MacOS/TapeUp uitest --record --out tmp/uitest

# The UI test again, calling the user's own Claude Code and Codex for real.
uitest-agents:
	scripts/bundle.sh
	TAPEUP_AGENT_TEST=1 .build/TapeUp.app/Contents/MacOS/TapeUp uitest --agent claude --out tmp/uitest-claude
	TAPEUP_AGENT_TEST=1 .build/TapeUp.app/Contents/MacOS/TapeUp uitest --agent codex --out tmp/uitest-codex

bundle:
	scripts/bundle.sh release

# Replaces /Applications/TapeUp.app with a fresh build and opens it.
install: bundle
	-pkill -x TapeUp
	while pgrep -x TapeUp >/dev/null; do sleep 0.2; done
	rm -rf /Applications/TapeUp.app
	ditto .build/TapeUp.app /Applications/TapeUp.app
	open /Applications/TapeUp.app

# Builds, signs and publishes a release from this Mac: make release VERSION=0.1.0
# (scripts/release.sh --dry-run 0.1.0 tries it without publishing).
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=0.1.0"; exit 2; }
	scripts/release.sh $(VERSION)

test:
	swift test
