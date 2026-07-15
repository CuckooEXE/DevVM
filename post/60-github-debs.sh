#!/usr/bin/env bash
# Install cached .deb packages that came from the github_releases section.
#
# Some upstreams (bindiff, rustdesk) ship ONLY a .deb — no tarball — so
# their github_releases stanzas carry no `bin:` entries and exist purely
# to cache the .deb under cache/github/<repo>/<tag>/ during prepare. This
# hook dpkg-installs whatever landed there, fully offline.
#
# Idempotent: re-installing an already-current .deb is a no-op. Never
# aborts the run — a missing dep on an offline box is reported, not fatal.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CACHE="${ROOT}/cache/github"

if [ ! -d "${CACHE}" ]; then
    echo "post/60-github-debs: no ${CACHE}; nothing to install" >&2
    exit 0
fi

shopt -s nullglob
debs=("${CACHE}"/*/*/*.deb)
shopt -u nullglob

if [ "${#debs[@]}" -eq 0 ]; then
    echo "post/60-github-debs: no cached .deb packages found" >&2
    exit 0
fi

for deb in "${debs[@]}"; do
    echo "post/60-github-debs: installing ${deb##*/}"
    # apt-get resolves + pulls deps from configured repos; fall back to a
    # dpkg + -f install repair when it can't (e.g. fully offline).
    if ! sudo apt-get install -y "${deb}"; then
        echo "post/60-github-debs: apt install failed for ${deb##*/}; trying dpkg + -f" >&2
        sudo dpkg -i "${deb}" || true
        sudo apt-get -f install -y || true
    fi
done
