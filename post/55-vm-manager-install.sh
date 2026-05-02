#!/usr/bin/env bash
# Install bin/vm-manager.sh onto $PATH as /usr/local/bin/vm-manager.
# Idempotent. Re-running setup.py refreshes the deployed copy.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

src="$REPO_ROOT/bin/vm-manager.sh"
dst="/usr/local/bin/vm-manager"

if [[ ! -f "$src" ]]; then
    echo "post/55-vm-manager-install: $src missing; skipping"
    exit 0
fi

echo "post/55-vm-manager-install: installing $dst"
sudo install -m 0755 "$src" "$dst"
