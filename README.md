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
docker images, zeal docsets, fonts, Codium extensions, and the offline
LazyVim bundle are all declared there. Each section's inline comments
show a usage example per entry.

## Two-stage flow for offline installs

`bootstrap.sh` and `setup.py` both split into `prepare` (download
everything into `cache/`) and `install` (apply from that cache). Run
`prepare` on a connected machine, ship repo + `cache/` to the offline
target, then run `install` there.

```bash
# on a connected machine — fills cache/ with everything:
./bootstrap.sh full               # installs host prereqs + caches their .debs
python3 setup.py --mode prepare   # caches every artifact under cache/*/

# ship repo + cache to the target, then on the target:
./bootstrap.sh install            # dpkg -i the bootstrap debs (no network)
python3 setup.py --mode install   # installs from cache (no network)
```

Every installer honours the offline contract: apt downloads the whole
transitive `.deb` closure, pipx builds wheels locally, rustup stages a
full `~/.rustup` tree into the cache, Codium extensions pre-fetch
`.vsix` bundles from Open VSX, the LazyVim bundle pre-clones
every plugin and pre-installs every Mason server. See `vmconfig.yaml`
section-by-section for details.

`./bootstrap.sh --help` and `python3 setup.py --help` print the full
flag and subcommand lists.

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
`rustup`, `git_sources`, `docker`, `docs`, `fonts`, `codium_extensions`,
`neovim_offline`.

## Repo layout

- `bootstrap.sh` — host apt prereqs only (`prepare`/`install`/`full`
  subcommands). Doesn't run `setup.py` — invoke it yourself afterwards.
- `setup.py` — orchestrator (Python stdlib + PyYAML + jsonschema).
- `vmconfig.yaml` — the config. Edit freely; inline comments document
  every package/repo/image.
- `schema.json` — JSON Schema validating `vmconfig.yaml`.
- `vmconfig.lock` — pinned versions resolved in the last `prepare` run.
  Commit for reproducibility.
- `installers/` — one module per section. `installers/neovim_offline/`
  is a package containing the LazyVim bundle's source + deploy scripts.
- `post/` — shell hooks run after installers, lexical order.
- `cache/` — populated by `prepare`, consumed by `install`. Gitignored.
- `tests/run-vm.sh` — end-to-end test harness. See `tests/README.md`.

## Offline LazyVim bundle

Every plugin pre-cloned, every Mason LSP/DAP/formatter pre-installed,
treesitter parsers pre-compiled. Source and scripts live under
`installers/neovim_offline/`; staged artifacts land in
`cache/neovim_offline/`. `--mode prepare` stages, `--mode install`
deploys into the invoking user's `$HOME`. Full details in
`installers/neovim_offline/README.md`.

## Testing

End-to-end harness that boots a Debian Trixie cloud image under QEMU,
rsyncs the repo in, and runs the full install:

```bash
tests/run-vm.sh                    # boot + install + interactive SSH shell
tests/run-vm.sh --help             # all subcommands and flags
tests/run-vm.sh sync               # push host repo edits into the running VM
tests/run-vm.sh pull-cache         # copy VM's cache/ back to the host
tests/run-vm.sh push-cache         # seed the VM's cache/ from the host
```

See `tests/README.md` for prereqs, validation checks, and the cloud-init
details.
