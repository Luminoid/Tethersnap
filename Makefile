.PHONY: help lint lint-fix format check setup-hooks build test
.DEFAULT_GOAL := help

help:
	@echo "Project targets:"
	@echo "  make build        swift build or xcodebuild"
	@echo "  make test         swift test or xcodebuild test"
	@echo "  make lint         Run SwiftLint"
	@echo "  make lint-fix     Run SwiftLint --fix"
	@echo "  make format       Run SwiftFormat (modifies files)"
	@echo "  make check        Strict lint + format check (CI gate)"
	@echo "  make setup-hooks  Install pre-commit hooks"

lint:
	swiftlint

lint-fix:
	swiftlint --fix

format:
	swiftformat .

check:
	swiftlint --strict
	swiftformat --lint .

setup-hooks:
	git config core.hooksPath Scripts/git-hooks
	@echo "Git hooks configured to Scripts/git-hooks/"

build:
	swift build

test:
	swift test
