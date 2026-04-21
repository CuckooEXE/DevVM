# DevVMSetup

Declarative, idempotent provisioner for a Debian Trixie dev/research VM.
Edit `vmconfig.yaml`, run `./bootstrap.sh && python3 setup.py --mode full`,
snapshot the VM.

## Quick start

```bash
./bootstrap.sh                    # install host apt prereqs for setup.py
python3 setup.py --mode full      # install everything declared in vmconfig.yaml
```

That's it. `vmconfig.yaml` is the single source of truth — apt packages,
pipx/pip libs, GitHub-release binaries, tarballs, rustup, git clones,
docker images, zeal docsets, fonts, VSCode extensions, and the offline
LazyVim bundle are all declared there. Each section's inline comments
show a usage example per entry.

## Two-stage flow for offline installs

`bootstrap.sh` and `setup.py` both split into `prepare` (download) and
`install` (apply from cache). Run `prepare` on a connected machine to
fill `./cache/`, ship the repo + cache to an offline target, then run
`install` there.

```bash
# on a connected machine:
./bootstrap.sh prepare            # .debs         → cache/bootstrap/debs/
python3 setup.py --mode prepare   # everything    → cache/*/

# ship the repo + cache to the target, then on the target:
./bootstrap.sh install            # dpkg -i from cache, no network
python3 setup.py --mode install   # installs from cache, no network
```

Both sides accept `--mode full` for a one-shot online run (the default
for `setup.py`; `./bootstrap.sh` alone is equivalent to
`./bootstrap.sh full`).

## setup.py flags

| Flag                      | Purpose                                                                  |
|---------------------------|--------------------------------------------------------------------------|
| `--mode {prepare,install,full}` | phase to run (default: full)                                       |
| `--only SECTION`          | limit to named section(s); repeatable                                    |
| `--skip SECTION`          | skip named section(s); repeatable (e.g. when GitHub rate-limits you)     |
| `--refresh`               | re-resolve 'latest' tags; ignore `vmconfig.lock`                         |
| `--dry-run`               | print actions without executing                                          |
| `-v`                      | verbose logging                                                          |

Section names: `apt`, `pipx`, `pip_system`, `github_releases`, `tarballs`,
`rustup`, `git_sources`, `docker`, `docs`, `fonts`, `vscode_extensions`,
`neovim_offline`.

## Repo layout

- `bootstrap.sh` — host apt prereqs only; doesn't run `setup.py`.
- `setup.py` — orchestrator (Python stdlib + PyYAML + jsonschema).
- `vmconfig.yaml` — the config. Edit freely.
- `schema.json` — JSON Schema validating `vmconfig.yaml`.
- `vmconfig.lock` — pinned versions resolved in the last `prepare` run.
  Commit for reproducibility.
- `installers/` — one module per section.
- `post/` — shell hooks run after installers, lexical order.
- `cache/` — populated by `prepare`, consumed by `install`. Gitignored.
- `tests/run-vm.sh` — end-to-end test harness (boots a Debian cloud image
  under QEMU and runs the full install). See `tests/README.md`.

## Offline LazyVim bundle

Every plugin pre-cloned, every Mason LSP/DAP/formatter pre-installed,
treesitter parsers pre-compiled. Driven by the `neovim_offline` section
of `vmconfig.yaml` and lives under `installers/neovim_offline/`.
`--mode prepare` stages everything into `cache/neovim_offline/`;
`--mode install` deploys that cache into the invoking user's `$HOME`.
See `installers/neovim_offline/README.md` for details.

## Testing

```bash
tests/run-vm.sh            # boot Debian Trixie cloud image, run the full
                           # install, drop into an interactive SSH shell
tests/run-vm.sh --help     # subcommands (boot/ssh/sync/destroy/...) and flags
```
