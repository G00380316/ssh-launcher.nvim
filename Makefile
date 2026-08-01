.PHONY: test lint format docs all

NVIM ?= nvim

all: lint test

# The suite is self-contained: no plenary, no busted, no network.
test:
	@$(NVIM) --headless -u NONE -l tests/run.lua

# CI checks the same paths; keep the two in step or formatting drifts back in.
SOURCES = lua tests plugin

# Fall back to npx so `make lint` and `make format` work without a global
# install — an unformatted push is otherwise only caught in CI.
STYLUA = $(shell command -v stylua 2>/dev/null || echo "npx --yes @johnnymorganz/stylua-bin@latest")

lint:
	@$(STYLUA) --check $(SOURCES)
	@command -v luacheck >/dev/null 2>&1 \
		&& luacheck $(SOURCES) \
		|| echo "luacheck not installed; skipping"

format:
	@$(STYLUA) $(SOURCES)

# Regenerate helptags so :help ssh-launcher works from a checkout.
docs:
	@$(NVIM) --headless -u NONE -c "helptags doc" -c q
	@echo "helptags written to doc/tags"
