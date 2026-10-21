# rayzip — common tasks. `make` (or `make help`) lists them.

.DEFAULT_GOAL := help
.PHONY: help build test test-native fmt bench clean

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-12s %s\n", $$1, $$2}'

build: ## The native binary, ./rayzip
	rm -f rayzip
	ray build --native --release -o rayzip src/main.ray

test: ## Tests on the VM (the interop ones use zip, unzip and gzip if installed)
	ray test

test-native: ## The same tests as native binaries
	ray test --native

fmt: ## Format the sources
	ray fmt -w src/*.ray tests/*.ray

bench: build ## rayzip against zip/unzip/gzip on a generated corpus (BENCH_DIR, default /tmp)
	scripts/bench.sh

clean: ## Remove the binary
	rm -f rayzip
