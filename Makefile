# Second Brain — common tasks. Brain targets run from brain/, agent targets from mac-agent/.
PY ?= python3
VENV ?= brain/.venv
VPY := $(VENV)/bin/python

.PHONY: help venv test eval run up down logs agent agent-test agent-install backup

help:
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-14s %s\n", $$1, $$2}'

$(VPY):
	$(PY) -m venv $(VENV) && $(VPY) -m pip install -q -e 'brain[dev]'

venv: $(VPY) ## create brain/.venv with dev deps

test: $(VPY) ## brain unit tests (fake LLM, no network)
	cd brain && $(abspath $(VPY)) -m pytest -q

eval: $(VPY) ## run the golden set against the live vLLM (uses ./config.yaml for llm.*)
	cd brain && $(abspath $(VPY)) -m app.eval --config ../config.yaml $(ARGS)

run: $(VPY) ## run the brain locally on :8080 with ./config.yaml (db in brain/data)
	cd brain && HA_CONFIG=../config.yaml HA_DB_PATH=data/brain.db $(abspath $(VPY)) -m uvicorn app.main:factory --factory --port 8080 --reload

up: ## docker compose up -d (brain)
	cd brain && docker compose up -d --build

down:
	cd brain && docker compose down

logs:
	cd brain && docker compose logs -f --tail=200

agent: ## build the mac-agent (macOS)
	cd mac-agent && swift build -c release

agent-test: ## mac-agent unit tests
	cd mac-agent && swift test

agent-install: ## build, sign, install + load the LaunchAgent (macOS; set SIGN_IDENTITY)
	cd mac-agent && ./scripts/install.sh
