#!/bin/bash
# Tests for the classification functions in categorize-conflicts.sh.
#
# Usage: test-categorize-conflicts.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=ai/skills/resolve-conflicts/scripts/categorize-conflicts.sh
source "$SCRIPT_DIR/categorize-conflicts.sh"

passes=0
failures=0

assert() {
    local description="$1"
    shift
    local rc=0
    "$@" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: $description"
        failures=$((failures + 1))
    fi
}

assert_not() {
    local description="$1"
    shift
    local rc=0
    "$@" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: $description"
        failures=$((failures + 1))
    fi
}

# --- is_lockfile ---

assert "package-lock.json is lockfile" is_lockfile "package-lock.json"
assert "nested package-lock.json is lockfile" is_lockfile "frontend/package-lock.json"
assert "yarn.lock is lockfile" is_lockfile "yarn.lock"
assert "pnpm-lock.yaml is lockfile" is_lockfile "pnpm-lock.yaml"
assert "Cargo.lock is lockfile" is_lockfile "Cargo.lock"
assert "poetry.lock is lockfile" is_lockfile "poetry.lock"
assert "Gemfile.lock is lockfile" is_lockfile "Gemfile.lock"
assert "composer.lock is lockfile" is_lockfile "composer.lock"
assert "bun.lockb is lockfile" is_lockfile "bun.lockb"
assert "bun.lock is lockfile" is_lockfile "bun.lock"
assert_not "package.json is not lockfile" is_lockfile "package.json"
assert_not "Cargo.toml is not lockfile" is_lockfile "Cargo.toml"
assert_not "random.lock is not lockfile" is_lockfile "random.lock"

# --- is_migration ---

assert "migrations/ root" is_migration "migrations/0001_init.py"
assert "nested migrations/" is_migration "app/migrations/0001_init.py"
assert "alembic/ root" is_migration "alembic/versions/abc123.py"
assert "nested alembic/" is_migration "src/alembic/versions/abc123.py"
assert "db/migrate/" is_migration "db/migrate/20210101_create.rb"
assert "nested db/migrate/" is_migration "app/db/migrate/20210101_create.rb"
assert_not "alembic env.py not migration" is_migration "alembic/env.py"
assert_not "bare migrate/ not matched" is_migration "cmd/migrate/main.go"
assert_not "regular source file" is_migration "src/app.py"

# --- is_mergiraf_supported ---

# Core language extensions
assert "Rust (.rs)" is_mergiraf_supported "src/main.rs"
assert "Go (.go)" is_mergiraf_supported "cmd/server.go"
assert "Java (.java)" is_mergiraf_supported "App.java"
assert "Python (.py)" is_mergiraf_supported "app.py"
assert "TypeScript (.ts)" is_mergiraf_supported "index.ts"
assert "TSX (.tsx)" is_mergiraf_supported "App.tsx"
assert "JavaScript (.js)" is_mergiraf_supported "script.js"
assert "JSON (.json)" is_mergiraf_supported "config.json"
assert "YAML (.yml)" is_mergiraf_supported "config.yml"
assert "YAML (.yaml)" is_mergiraf_supported "config.yaml"
assert "TOML (.toml)" is_mergiraf_supported "config.toml"

# New extensions added from mergiraf languages
assert "INI (.ini)" is_mergiraf_supported "config.ini"
assert "SystemVerilog (.sv)" is_mergiraf_supported "module.sv"
assert "SystemVerilog header (.svh)" is_mergiraf_supported "defines.svh"
assert "Markdown (.md)" is_mergiraf_supported "README.md"
assert "HCL (.hcl)" is_mergiraf_supported "main.hcl"
assert "Terraform (.tf)" is_mergiraf_supported "main.tf"
assert "Terraform vars (.tfvars)" is_mergiraf_supported "prod.tfvars"
assert "OCaml (.ml)" is_mergiraf_supported "main.ml"
assert "OCaml interface (.mli)" is_mergiraf_supported "sig.mli"
assert "Haskell (.hs)" is_mergiraf_supported "Main.hs"
assert "GNU Make (.mk)" is_mergiraf_supported "rules.mk"
assert "Starlark (.bzl)" is_mergiraf_supported "defs.bzl"
assert "Starlark (.bazel)" is_mergiraf_supported "build.bazel"
assert "CMake (.cmake)" is_mergiraf_supported "FindFoo.cmake"

# Name-based matches
assert "go.mod" is_mergiraf_supported "go.mod"
assert "go.sum" is_mergiraf_supported "go.sum"
assert "go.work.sum" is_mergiraf_supported "go.work.sum"
assert "pyproject.toml" is_mergiraf_supported "pyproject.toml"
assert "Makefile" is_mergiraf_supported "Makefile"
assert "GNUmakefile" is_mergiraf_supported "GNUmakefile"
assert "BUILD" is_mergiraf_supported "BUILD"
assert "WORKSPACE" is_mergiraf_supported "WORKSPACE"
assert "CMakeLists.txt" is_mergiraf_supported "CMakeLists.txt"

# Nested paths for name-based matches
assert "nested Makefile" is_mergiraf_supported "src/Makefile"
assert "nested CMakeLists.txt" is_mergiraf_supported "lib/CMakeLists.txt"

# Not supported
assert_not ".txt not supported" is_mergiraf_supported "readme.txt"
assert_not ".sh not supported" is_mergiraf_supported "script.sh"
assert_not ".css not supported" is_mergiraf_supported "style.css"
assert_not ".sql not supported" is_mergiraf_supported "query.sql"

# --- Priority: lockfile beats mergiraf ---

# package-lock.json has .json extension (mergiraf-supported) but should be a lockfile.
assert "package-lock.json is lockfile (priority)" is_lockfile "package-lock.json"
assert "Cargo.lock is lockfile not mergiraf" is_lockfile "Cargo.lock"

# --- Summary ---

echo ""
echo "Results: $passes passed, $failures failed"
if [[ "$failures" -gt 0 ]]; then
    exit 1
fi
