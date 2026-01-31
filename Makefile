.PHONY: ci ci-debug help

help:
	@echo "Available targets:"
	@echo "  make ci       - Run local CI simulation (same as GitHub Actions)"
	@echo "  make ci-debug - Run CI with maximum verbosity and always collect debug bundle"

ci:
	@bash scripts/ci-local.sh

ci-debug:
	@bash scripts/ci-local.sh --debug
