.PHONY: test lint format docs all

NVIM ?= nvim

all: lint test

# The suite is self-contained: no plenary, no busted, no network.
test:
	@$(NVIM) --headless -u NONE -l tests/run.lua

lint:
	@command -v stylua >/dev/null 2>&1 \
		&& stylua --check lua tests \
		|| echo "stylua not installed; skipping"
	@command -v luacheck >/dev/null 2>&1 \
		&& luacheck lua tests --globals vim \
		|| echo "luacheck not installed; skipping"

format:
	@stylua lua tests

# Regenerate helptags so :help ssh-launcher works from a checkout.
docs:
	@$(NVIM) --headless -u NONE -c "helptags doc" -c q
	@echo "helptags written to doc/tags"
