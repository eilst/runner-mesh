.PHONY: doctor lint test

doctor:
	./bin/runner-mesh doctor

lint:
	shellcheck bin/runner-mesh lib/*.sh
	bash -n bin/runner-mesh
	for f in lib/*.sh; do bash -n "$$f"; done

test:
	@echo "See .github/workflows/smoke-test.yml — runs against a throwaway k3d cluster."
	@echo "Requires: k3d, helm, kubectl, jq installed locally."
