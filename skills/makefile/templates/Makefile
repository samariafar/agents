SHELL := $(shell command -v bash)

.SILENT:
.ONESHELL:
.DEFAULT_GOAL := help
.PHONY: help sampleCommand

help: ## Show available commands
	echo -e "\nUsage:\n"
	grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2}'
	echo

sampleCommand:
	echo "OK"

%:
	:
