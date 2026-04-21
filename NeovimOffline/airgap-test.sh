#!/usr/bin/env bash
# airgap-test.sh — Verify the bundle works with zero internet, on THIS machine.
#
# Creates a throwaway fake HOME in /tmp, runs install.sh into it, then drops
# into a network namespace with no connectivity and launches nvim. When you
# quit nvim, the fake home is left in place so you can inspect it; rerun with
# --clean to wipe it.

set -euo pipefail

BUNDLE="$(cd "$(dirname "$0")" && pwd)"
FAKE_HOME="/tmp/nvim-airgap-test"

if [[ "${1:-}" == "--clean" ]]; then
  rm -rf "$FAKE_HOME"
  echo "removed $FAKE_HOME"
  exit 0
fi

if [[ ! -d "$BUNDLE/share/nvim/lazy" || ! -d "$BUNDLE/share/nvim/mason" ]]; then
  echo "bundle not staged yet — run ./stage.sh first" >&2
  exit 1
fi

# Namespace sanity-check before we install anything.
if ! unshare -rn true 2>/dev/null; then
  echo "This kernel doesn't allow unprivileged user namespaces." >&2
  echo "Try: sudo sysctl kernel.unprivileged_userns_clone=1" >&2
  exit 1
fi

echo "[airgap-test] installing bundle into $FAKE_HOME …"
mkdir -p "$FAKE_HOME"
HOME="$FAKE_HOME" "$BUNDLE/install.sh" --force

# Leave a small sandbox of test files to poke at inside nvim.
mkdir -p "$FAKE_HOME/sandbox"
cat > "$FAKE_HOME/sandbox/test.c" <<'C'
#include <stdio.h>

int add(int a, int b) {
    return a + b;
}

int main(void) {
    int x = add(2, 3);
    printf("%d\n", x);
    return 0;
}
C

cat > "$FAKE_HOME/sandbox/test.py" <<'PY'
def greet(name: str) -> str:
    return f"hello, {name}"


if __name__ == "__main__":
    print(greet("world"))
PY

cat > "$FAKE_HOME/sandbox/test.zig" <<'ZIG'
const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("hello, zig\n", .{});
}
ZIG

cat > "$FAKE_HOME/sandbox/Taskfile.yml" <<'TASK'
version: '3'
tasks:
  hello:
    cmds:
      - echo "hello from taskfile"
  build:
    cmds:
      - gcc -o test test.c
TASK

cat > "$FAKE_HOME/sandbox/Makefile" <<'MAKE'
CC = gcc
CFLAGS = -Wall -O2

test: test.c
	$(CC) $(CFLAGS) -o test test.c

.PHONY: clean
clean:
	rm -f test
MAKE

echo
echo "[airgap-test] dropping into airgapped namespace (no internet) …"
echo "  - try: gd (goto def), K (hover), <leader>ff (find files), :Lazy, :Mason"
echo "  - outside nvim in this shell: curl https://github.com  -> DNS fail = good"
echo

exec unshare -rn env \
  HOME="$FAKE_HOME" \
  PATH="$FAKE_HOME/.local/bin:/usr/bin:/bin" \
  JAVA_HOME="$FAKE_HOME/.local/share/jdk-21" \
  XDG_CONFIG_HOME="$FAKE_HOME/.config" \
  XDG_DATA_HOME="$FAKE_HOME/.local/share" \
  TERM="$TERM" \
  bash --norc -c "cd $FAKE_HOME/sandbox && exec nvim test.zig"
