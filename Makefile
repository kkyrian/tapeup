.PHONY: verify-fast verify-full bundle install test

verify-fast:
	python3 scripts/agent-workspace/install-hooks.py --check
	swift format lint --strict -r Sources Tests Package.swift
	swift build
	swift test

verify-full: verify-fast
	scripts/bundle.sh release
	mise exec -- osv-scanner scan source --allow-no-lockfiles .

bundle:
	scripts/bundle.sh release

# Replaces /Applications/TapeUp.app with a fresh build and opens it.
install: bundle
	-pkill -x TapeUp
	rm -rf /Applications/TapeUp.app
	ditto .build/TapeUp.app /Applications/TapeUp.app
	open /Applications/TapeUp.app

test:
	swift test
