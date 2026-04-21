#!/usr/bin/env bash
# Simple smoke tests for DevVMSetup.
#
# Usage:
#   ./test.sh             # fast local checks (no Docker, no installs)
#   ./test.sh --docker    # re-run the same checks inside debian:trixie
#   ./test.sh --e2e       # real install in debian:trixie using test/vmconfig.test.yaml
#   ./test.sh --full      # local + docker + e2e
set -euo pipefail

# Script lives in test/; cd up to project root so paths like `bootstrap.sh`,
# `vmconfig.yaml`, `installers/` resolve.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
pass() { printf "  %sOK%s  %s\n"   "$GREEN" "$RESET" "$1"; }
fail() { printf "  %sFAIL%s %s\n"  "$RED"   "$RESET" "$1"; exit 1; }
info() { printf "%s==>%s %s\n"     "$YELLOW" "$RESET" "$1"; }

# ---------------------------------------------------------------------------
# The actual checks — run in-place on the host, no mutation of the system.
# ---------------------------------------------------------------------------
run_local_checks() {
    info "1/6 bash syntax"
    bash -n bootstrap.sh           && pass "bootstrap.sh parses"
    bash -n test/test.sh           && pass "test/test.sh parses"
    for h in post/*.sh; do
        bash -n "$h"               && pass "$h parses"
    done

    info "2/6 file permissions"
    [[ -x bootstrap.sh ]]          && pass "bootstrap.sh is +x"
    for h in post/*.sh; do
        [[ -x "$h" ]]              && pass "$h is +x"
    done

    info "3/6 Python syntax"
    python3 -m py_compile setup.py installers/*.py
    pass "setup.py and all installers compile"

    info "4/6 schema + config validation"
    # Use a throwaway venv so we don't touch the system python.
    VENV="$(mktemp -d)/venv"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet pyyaml jsonschema
    "$VENV/bin/python3" - <<'PY' || fail "schema validation failed"
import json, yaml, sys
from jsonschema import Draft202012Validator
cfg = yaml.safe_load(open("vmconfig.yaml"))
schema = json.load(open("schema.json"))
errs = sorted(Draft202012Validator(schema).iter_errors(cfg), key=lambda e: tuple(e.absolute_path))
if errs:
    for e in errs:
        path = "/" + "/".join(str(p) for p in e.absolute_path)
        print(f"  ERR at {path}: {e.message}", file=sys.stderr)
    sys.exit(1)
print(f"  {len(cfg)} sections, {sum(1 for _ in errs)} errors")
PY
    pass "vmconfig.yaml validates against schema.json"

    info "5/6 every section in config has a loadable installer"
    "$VENV/bin/python3" - <<'PY' || fail "missing installer module"
import importlib, sys, yaml
sys.path.insert(0, ".")
cfg = yaml.safe_load(open("vmconfig.yaml"))
for section in cfg.keys():
    try:
        m = importlib.import_module(f"installers.{section}")
    except ModuleNotFoundError:
        print(f"  MISSING installer for section: {section}", file=sys.stderr)
        sys.exit(1)
    has_prep = hasattr(m, "prepare")
    has_inst = hasattr(m, "install")
    if not (has_prep or has_inst):
        print(f"  {section}: installer has neither prepare() nor install()", file=sys.stderr)
        sys.exit(1)
    print(f"  {section}: prepare={has_prep} install={has_inst}")
PY
    pass "all config sections resolve to installers"

    info "6/6 dry-run install dispatches cleanly"
    # --mode install --dry-run does not hit the network (except for a one-time
    # cached repo-key download if the cache is empty), does not touch files
    # outside ./cache/, and exercises every installer's dispatch path.
    LOG="$(mktemp)"
    if "$VENV/bin/python3" setup.py --mode install --dry-run > "$LOG" 2>&1; then
        lines=$(wc -l < "$LOG")
        grep -q '\[install\] apt'             "$LOG" || fail "no 'apt' dispatch in log"
        grep -q '\[install\] github_releases' "$LOG" || fail "no 'github_releases' dispatch in log"
        grep -q '\[install\] docker'          "$LOG" || fail "no 'docker' dispatch in log"
        grep -q 'done (mode=install)'         "$LOG" || fail "setup.py did not reach clean exit"
        pass "dry-run install produced $lines lines and exited 0"
        rm -f "$LOG"
    else
        echo "--- setup.py output (first 60 lines) ---"
        head -n 60 "$LOG"
        fail "setup.py exited non-zero"
    fi

    rm -rf "$(dirname "$VENV")"
}

# ---------------------------------------------------------------------------
# Optional: re-run the same checks inside an actual debian:trixie container.
# Catches issues that only show up on the real target (path-case, package
# availability, jsonschema version in Trixie, etc.).
# ---------------------------------------------------------------------------
run_docker_checks() {
    info "docker: running test.sh inside debian:trixie"
    if ! command -v docker >/dev/null 2>&1; then
        fail "docker CLI not on PATH"
    fi

    # --network=bridge for `apt-get install`; no volumes other than read-only project.
    docker run --rm \
        -v "$ROOT:/work:ro" \
        -w /work \
        debian:trixie \
        bash -c '
            set -eu
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y --no-install-recommends \
                python3 python3-yaml python3-jsonschema ca-certificates >/dev/null

            # We cannot write to /work (read-only mount). Copy to /tmp/run.
            cp -r /work /tmp/run
            cd /tmp/run
            ./test/test.sh
        '
    pass "debian:trixie smoke test passed"
}

# ---------------------------------------------------------------------------
# End-to-end: actually run bootstrap.sh + setup.py inside a fresh
# debian:trixie container, using a minimal test config. Verifies every
# installer type produces its artifact.
# ---------------------------------------------------------------------------
run_e2e_checks() {
    info "e2e: running real install inside devvmsetup-test (config: test/vmconfig.test.yaml)"
    if ! command -v docker >/dev/null 2>&1; then
        fail "docker CLI not on PATH"
    fi
    [[ -f test/vmconfig.test.yaml ]] || fail "test/vmconfig.test.yaml missing"
    [[ -f test/Dockerfile ]]         || fail "test/Dockerfile missing"

    info "building devvmsetup-test image (cached after first run)"
    docker build -q -t devvmsetup-test test/ >/dev/null
    pass "devvmsetup-test image ready"

    # The image USER is `tester`, so commands run inside are already tester —
    # no `su` needed, no password prompt. The entrypoint auto-wires tester
    # into the host-docker socket's group, so no `--group-add` needed.
    docker run --rm -i \
        -v "$ROOT:/src:ro" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        devvmsetup-test \
        bash -eu <<'CONTAINER'
echo "==> running bootstrap.sh --mode full --config test/vmconfig.test.yaml"
cd ~/DevVMSetup && ./bootstrap.sh --mode full --config test/vmconfig.test.yaml

echo
echo "==> verifying every installer type produced its artifact"

fail_inner() { echo "  FAIL: $1" >&2; exit 1; }
ok()         { echo "  OK:   $1"; }

command -v jq >/dev/null                && ok "apt: jq on PATH"                    || fail_inner "apt: jq missing"
jq --version >/dev/null                 && ok "apt: jq runs"                       || fail_inner "apt: jq broken"

test -x "$HOME/.local/bin/ruff"         && ok "pipx: ruff in ~/.local/bin"          || fail_inner "pipx: ruff missing"
"$HOME/.local/bin/ruff" --version >/dev/null \
                                        && ok "pipx: ruff runs"                     || fail_inner "pipx: ruff broken"

python3 -c 'import requests; print("    requests", requests.__version__)' \
                                        && ok "pip_system: requests importable"     || fail_inner "pip_system: requests missing"

command -v hyperfine >/dev/null         && ok "github_releases: hyperfine on PATH"  || fail_inner "github_releases: hyperfine missing"
hyperfine --version >/dev/null          && ok "github_releases: hyperfine runs"     || fail_inner "github_releases: hyperfine broken"

test -L /opt/zig/current                && ok "tarballs: /opt/zig/current exists"   || fail_inner "tarballs: zig install missing"
command -v zig >/dev/null               && ok "tarballs: zig on PATH"               || fail_inner "tarballs: zig symlink missing"
zig version >/dev/null 2>&1             && ok "tarballs: zig runs"                  || fail_inner "tarballs: zig broken"

test -x "$HOME/.cargo/bin/rustc"        && ok "rustup: rustc installed"             || fail_inner "rustup: rustc missing"
test -x "$HOME/.cargo/bin/cargo"        && ok "rustup: cargo installed"             || fail_inner "rustup: cargo missing"
"$HOME/.cargo/bin/rustc" --version >/dev/null \
                                        && ok "rustup: rustc runs"                  || fail_inner "rustup: rustc broken"

docker image inspect hello-world:latest >/dev/null 2>&1 \
                                        && ok "docker: hello-world image present"   || fail_inner "docker: pull failed"

test -f /etc/apt/sources.list.d/docker.list \
                                        && ok "apt.repos: docker repo configured"   || fail_inner "apt.repos: missing"
test -f /etc/apt/keyrings/docker.gpg    && ok "apt.repos: docker key installed"     || fail_inner "apt.repos: key missing"

test -d "$HOME/test-clone-gtfobins/.git" \
                                        && ok "git_sources: GTFOBins cloned"        || fail_inner "git_sources: clone missing"

test -s "$HOME/DevVMSetup/vmconfig.lock" \
                                        && ok "lock: vmconfig.lock written"         || fail_inner "lock: vmconfig.lock missing"

echo
echo "==> re-running bootstrap.sh to verify idempotency"
cd ~/DevVMSetup && ./bootstrap.sh --mode install --config test/vmconfig.test.yaml \
                                        && ok "idempotent: second install run exits 0"

echo
echo "e2e PASSED"
CONTAINER

    pass "debian:trixie end-to-end install passed"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
mode=local
case "${1:-}" in
    ""|--local) mode=local ;;
    --docker)   mode=docker ;;
    --e2e)      mode=e2e ;;
    --full)     mode=full ;;
    -h|--help)
        sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

case "$mode" in
    local)  run_local_checks ;;
    docker) run_docker_checks ;;
    e2e)    run_e2e_checks ;;
    full)   run_local_checks; run_docker_checks; run_e2e_checks ;;
esac

echo
printf "%sALL CHECKS PASSED%s\n" "$GREEN" "$RESET"
