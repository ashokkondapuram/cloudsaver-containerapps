.PHONY: build test check
BICEP ?= bicep
build:
	mkdir -p dist
	$(BICEP) build infra/main.bicep --outfile dist/main.json
	$(BICEP) build infra/environment.bicep --outfile dist/environment.json
test: build
	python3 -m unittest discover -s tests -v
check:
	python3 scripts/deploy.py check --config examples/production.json
