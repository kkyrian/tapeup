.PHONY: verify-fast verify-full bundle test

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

test:
	swift test
