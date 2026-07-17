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

# Deploy the default cloud-init seed dir where vm-manager resolves it
# (../share/vm-manager/cloud-init relative to /usr/local/bin/vm-manager).
ci_src="$REPO_ROOT/cloud-init"
ci_dst="/usr/local/share/vm-manager/cloud-init"
if [[ -d "$ci_src" ]]; then
    echo "post/55-vm-manager-install: installing cloud-init seed → $ci_dst"
    sudo install -d "$ci_dst"
    for f in "$ci_src"/*; do
        [[ -f "$f" ]] && sudo install -m 0644 "$f" "$ci_dst/$(basename "$f")"
    done
else
    echo "post/55-vm-manager-install: $ci_src missing; skipping cloud-init seed"
fi
