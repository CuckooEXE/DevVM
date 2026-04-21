# DevVMSetup

Declarative, idempotent provisioner for a Debian Trixie dev/research VM.
Edit `vmconfig.yaml`, run `./bootstrap.sh && python3 setup.py --mode full`,
snapshot the VM.

## Two-stage install

`bootstrap.sh` handles only the host-level apt prereqs that `setup.py` itself
needs to run (Python + PyYAML + jsonschema + gcc/make/unzip for staging).
`setup.py` is the actual orchestrator — invoke it directly once bootstrap is
done. Both scripts share a `prepare`/`install`/`full` split so a connected
machine can produce a `cache/` bundle that coworkers pick up for an offline
install.

```
# on a connected machine — fills cache/ with everything needed
./bootstrap.sh prepare            # downloads .debs to cache/bootstrap/debs/
python3 setup.py --mode prepare   # downloads GitHub assets, docker images, …

# ship cache/ + vmconfig.lock to the offline target machine, then:
./bootstrap.sh install            # dpkg -i from cache/bootstrap/debs/
python3 setup.py --mode install   # install everything else from cache/

# or for a one-shot online run on a single machine:
./bootstrap.sh                    # = prepare + install (default: full)
python3 setup.py --mode full      # = prepare + install
```

`setup.py --dry-run` prints the actions without executing them.

## Layout

- `bootstrap.sh` — bash entrypoint for host apt prereqs (prepare/install/full).
  Does **not** exec `setup.py` — users run that themselves.
- `setup.py` — orchestrator (Python stdlib + PyYAML + jsonschema).
- `vmconfig.yaml` — your config. Edit freely.
- `schema.json` — JSON Schema validating `vmconfig.yaml`.
- `vmconfig.lock` — pinned versions resolved in last `prepare`. Commit for reproducibility.
- `installers/` — one module per installer type.
- `post/` — shell hooks run after installers, lexical order.
- `cache/` — gitignored; populated by `prepare`, consumed by `install`.

## Sections in `vmconfig.yaml`

| Section           | Purpose                                                                     |
|-------------------|-----------------------------------------------------------------------------|
| `apt`             | apt repos + packages                                                         |
| `pipx`            | Python CLI tools, globally on `PATH` (e.g. `cz`, `poetry`)                  |
| `pip_system`      | Python libs importable from system python (uses `--break-system-packages`)   |
| `github_releases` | Latest GitHub Release binaries (e.g. `ripgrep`, `fd`, `bat`)                |
| `tarballs`        | Generic URL tarballs (Zig, Ghidra)                                          |
| `rustup`          | Rust toolchains, components, targets                                        |
| `git_sources`     | Clone git repos (single branch default, full-mirror option)                 |
| `docker`          | Images to pull (and optionally `docker save` to cache)                      |
| `docs`            | Man-db/info rebuilds, zeal docsets                                          |
| `vscode_extensions` | Marketplace IDs installed via `code --install-extension`                 |
| `NeovimOffline/`  | Bundled LazyVim + plugins + LSPs; `post/60-neovim-offline.sh` runs its installer |

## Reproducibility

`prepare` writes `vmconfig.lock` with the exact tag/SHA resolved for every
"latest" entry. Commit the lock file; future runs honor it unless `--refresh`
is passed.

## NeovimOffline bundle

`NeovimOffline/` is a self-contained, air-gap-safe LazyVim bundle (Neovim +
every plugin + every LSP/DAP/formatter + OpenJDK 21 for `jdtls`). The
JetBrainsMono Nerd Font it relies on for icon glyphs is installed separately,
system-wide, by `post/05-fonts.sh`. It has its own two-phase workflow that
mirrors this project's
`prepare`/`install` split:

1. On a **connected** machine: `cd NeovimOffline && ./stage.sh` (10-30 min,
   downloads ~350 MB of tarballs, plugin source, and Mason packages).
2. On the **offline** VM: the provisioner's `post/60-neovim-offline.sh` hook
   invokes `NeovimOffline/install.sh --force` automatically during
   `python3 setup.py --mode install`. It deploys the bundle into the invoking
   user's `$HOME` (`~/.config/nvim`, `~/.local/share/nvim{,-runtime}`,
   `~/.local/share/node`, `~/.local/share/jdk-21`) and appends
   `PATH` + `JAVA_HOME` exports to `~/.bashrc` + `~/.zshrc`.

The hook is defensive: skips if the bundle is missing, not staged, or already
deployed. `.gitignore` excludes the staged artifacts (`bin/`, `jdk/`,
`share/nvim/lazy`, `share/nvim/mason`) since they're large and
machine-reproducible via `stage.sh`.

## Testing

```
./test.sh              # ~5s local checks (syntax, schema, dispatch) — no Docker.

./test.sh --docker     # re-run smoke checks inside a fresh debian:trixie container.

./test.sh --e2e        # ~2-3 min. REAL install in a fresh debian:trixie container
                       # using test/vmconfig.test.yaml (a minimal config that
                       # exercises every installer type). Verifies the artifacts
                       # actually landed, then re-runs install to prove idempotency.

./test.sh --full       # all three.
```

The `--e2e` test uses `test/vmconfig.test.yaml` which exercises every
installer type with small artifacts: `jq` via apt, `ruff` via pipx,
`requests` via pip_system, `hyperfine` from a GitHub Release, zig via
tarballs+zig-index, rustup stable-minimal, GTFOBins via git_sources, and
`hello-world:latest` via docker (mounted host socket). All three previously-
out-of-scope installers (`rustup`, `tarballs`, `docker`) are now covered.

### Interactive inspection: `test2.sh`

```
./test2.sh                              # uses test/vmconfig.test.yaml
./test2.sh vmconfig.yaml                # full production config
```

Same sandbox as `test.sh --e2e`, but instead of programmatic verification it
**drops you into a shell as the provisioned `tester` user** so you can try
commands by hand (`jq --version`, `zig version`, `rustc --version`, `docker
image ls`, etc.). Exit the shell to tear the container down. The container
is named `devvmsetup-inspect` — you can attach from another terminal with
`docker exec -it devvmsetup-inspect bash` while it's running. If bootstrap
fails, you still get the shell so you can debug state.

---

# Index

Every tool in `vmconfig.yaml`, what it's for, and a one-liner to try it.

## `apt` — system packages

### Build / compilers

| Package | Purpose | Example |
|---|---|---|
| `build-essential` | Meta-package: gcc, g++, make, libc6-dev | `sudo apt install build-essential` |
| `gcc` | GNU C compiler | `gcc -O2 -Wall -o hello hello.c` |
| `g++` | GNU C++ compiler | `g++ -std=c++20 -O2 -o app app.cpp` |
| `clang` | LLVM C/C++ compiler | `clang -O2 -fsanitize=address -o app app.c` |
| `clang-tools` | clangd, scan-build, clang-check | `clangd --help` |
| `clang-tidy` | C/C++ linter | `clang-tidy src/*.c -- -Iinclude` |
| `clang-format` | C/C++/Java formatter | `clang-format -i src/*.c` |
| `lld` | LLVM linker | `clang -fuse-ld=lld ...` |
| `lldb` | LLVM debugger | `lldb ./a.out` |
| `gdb` | GNU debugger | `gdb --args ./a.out arg1` |
| `gdb-multiarch` | gdb for foreign architectures | `gdb-multiarch ./arm-binary` |
| `cmake` | Build-system generator | `cmake -B build && cmake --build build` |
| `ninja-build` | Fast build tool (use with cmake -G Ninja) | `ninja -C build` |
| `meson` | Modern build system (pairs with ninja) | `meson setup build && ninja -C build` |
| `pkg-config` | Compile/link-flag helper | `pkg-config --cflags --libs openssl` |
| `autoconf` | Generate configure scripts | `autoreconf -i` |
| `automake` | Makefile.am → Makefile.in | used via autoreconf |
| `libtool` | Portable shared-library builder | used by autotools projects |

### Languages

| Package | Purpose | Example |
|---|---|---|
| `python3` | Python 3 interpreter | `python3 -c 'print("hi")'` |
| `python3-dev` | Headers for building C extensions | needed by `pip install <C-ext>` |
| `python3-venv` | Virtualenv module | `python3 -m venv .venv && . .venv/bin/activate` |
| `python3-pip` | pip in system python | see `pip_system` section |
| `pipx` | Install Python apps in isolated envs | `pipx install ruff` |
| `default-jdk` | Java JDK (OpenJDK) | `javac Foo.java && java Foo` |
| `maven` | Java build tool | `mvn package` |
| `gradle` | Java/Kotlin build tool | `gradle build` |

### Reverse engineering / binary analysis

| Package | Purpose | Example |
|---|---|---|
| `socat` | Swiss-army socket tool | `socat TCP-LISTEN:4444,fork EXEC:/bin/bash` |
| `netcat-openbsd` | netcat (OpenBSD variant) | `nc -lvnp 4444` |
| `strace` | Trace syscalls | `strace -f -e trace=network ./bin` |
| `ltrace` | Trace library calls | `ltrace ./bin` |
| `edb-debugger` | Evan's ELF debugger (GUI) | `edb --run ./bin` |
| `ddd` | GUI frontend for gdb | `ddd ./bin` |
| `qemu-user` | Run foreign-arch userspace binaries | `qemu-aarch64 ./arm64-bin` |
| `qemu-user-static` | Static qemu (for chroot'd foreign binaries) | binfmt-misc registers it |
| `qemu-system-x86` | x86 system emulator | `qemu-system-x86_64 -m 2G disk.img` |
| `qemu-system-arm` | ARM system emulator | `qemu-system-aarch64 -M virt ...` |
| `qemu-system-mips` | MIPS system emulator | `qemu-system-mipsel -M malta ...` |
| `qemu-utils` | qemu-img, qemu-nbd | `qemu-img convert -O raw in.qcow2 out.img` |
| `patchelf` | Edit ELF rpath / interpreter | `patchelf --set-interpreter /lib/ld-linux.so.2 ./bin` |
| `upx-ucl` | Pack/unpack UPX-compressed binaries | `upx -d packed.bin` |
| `hexedit` | Interactive hex editor (ncurses) | `hexedit file.bin` |
| `bsdextrautils` | `hexdump`, `col`, `hexcat`, etc. | `hexdump -C file.bin` |
| `file` | Identify file type | `file ./unknown` |
| `binutils` | `objdump`, `nm`, `readelf`, `strings`, `ld` | `objdump -d ./bin` |
| `elfutils` | `eu-readelf`, `eu-addr2line`, etc. | `eu-readelf -a ./bin` |
| `apktool` | Decompile/rebuild Android APKs | `apktool d app.apk` |
| `openssl` | Crypto CLI | `openssl s_client -connect host:443` |
| `nasm` | x86 assembler | `nasm -f elf64 shellcode.asm -o shellcode.o` |
| `yasm` | Alt. x86 assembler | `yasm -f elf64 -o a.o a.asm` |
| `libc6-dbg` | glibc debug symbols (crucial for heap RE) | auto-loaded by gdb when present |
| `gcc-multilib` | Build 32-bit on 64-bit host (C) | `gcc -m32 -o hello hello.c` |
| `g++-multilib` | Same for C++ | `g++ -m32 -o app app.cpp` |
| `musl-tools` | `musl-gcc` for small static binaries | `musl-gcc -static -o hello hello.c` |
| `valgrind` | Memory-error / leak detector | `valgrind --leak-check=full ./bin` |
| `checksec` | ELF hardening checker | `checksec --file=./bin` |
| `libcapstone-dev` | Capstone disassembler (dev) | `pkg-config --cflags capstone` |
| `cstool` | Capstone CLI disassembler (ships inside `libcapstone-dev`) | `cstool x64 "55 48 89 e5"` |

### Fuzzing

| Package | Purpose | Example |
|---|---|---|
| `afl++` | Modern AFL coverage-guided fuzzer | `afl-fuzz -i in/ -o out/ -- ./bin @@` |

### Network recon / pentest

| Package | Purpose | Example |
|---|---|---|
| `nmap` | Port scanner | `nmap -sV -sC -p- 10.0.0.1` |
| `tcpdump` | Packet capture | `sudo tcpdump -i any -w capture.pcap` |
| `wireshark` | GUI packet analyzer | `wireshark capture.pcap` |
| `tshark` | CLI wireshark | `tshark -r capture.pcap -Y 'http.request'` |
| `masscan` | Ultra-fast port scanner (syn) | `sudo masscan 10.0.0.0/8 -p80 --rate 10000` |
| `proxychains4` | Route any TCP through a proxy | `proxychains4 nmap -sT 10.0.0.1` |
| `whois` | WHOIS lookups | `whois example.com` |
| `dnsutils` | `dig`, `nslookup`, `host` | `dig +short example.com` |
| `ldap-utils` | `ldapsearch`, `ldapadd`, etc. | `ldapsearch -x -H ldap://host -b dc=x,dc=y` |
| `smbclient` | SMB CLI client | `smbclient -L //host -U user` |
| `samba-common-bin` | `nmblookup`, `net` | `nmblookup -A 10.0.0.1` |
| `snmp` | `snmpwalk`, `snmpget` | `snmpwalk -v2c -c public 10.0.0.1` |
| `snmp-mibs-downloader` | Downloads the standard MIBs | enables named-OID output in snmp tools |
| `onesixtyone` | SNMP community scanner | `onesixtyone -c community.txt 10.0.0.1` |
| `netdiscover` | ARP scanner for local nets | `sudo netdiscover -i eth0` |
| `arp-scan` | Active ARP scanner | `sudo arp-scan -l` |

### Web-app testing

| Package | Purpose | Example |
|---|---|---|
| `sqlmap` | SQL injection tool | `sqlmap -u 'https://t/?id=1' --batch` |
| `dirb` | URL/dir brute-forcer | `dirb https://target` |
| `wfuzz` | Web fuzzer | `wfuzz -w words.txt https://t/FUZZ` |
| `ffuf` | Fast web fuzzer | `ffuf -w words -u https://t/FUZZ` |
| `whatweb` | Fingerprint web stack | `whatweb https://target` |

### Password attacks (authorized engagements / CTFs)

| Package | Purpose | Example |
|---|---|---|
| `hydra` | Network login brute-forcer | `hydra -l user -P pass.txt ssh://host` |
| `john` | John the Ripper | `john --wordlist=rockyou.txt hashes.txt` |
| `hashcat` | GPU-accelerated cracker | `hashcat -m 0 hashes.txt rockyou.txt` |
| `hashid` | Identify hash format | `hashid -m somehash` |

### Wireless

| Package | Purpose | Example |
|---|---|---|
| `aircrack-ng` | WiFi cracking suite | `airodump-ng wlan0mon` |
| `reaver` | WPS PIN brute-force | `reaver -i mon0 -b AA:BB:... -vv` |

### Post-exploitation helpers

| Package | Purpose | Example |
|---|---|---|

### Forensics

| Package | Purpose | Example |
|---|---|---|
| `sleuthkit` | Filesystem forensics toolkit | `fls -r image.dd` |
| `foremost` | File carving | `foremost -i image.dd -o out/` |
| `scalpel` | File carving (alt.) | `scalpel -c scalpel.conf image.dd` |
| `libimage-exiftool-perl` | Provides `exiftool` | `exiftool photo.jpg` |

### Observability / kernel tracing (eBPF etc.)

| Package | Purpose | Example |
|---|---|---|
| `bpftrace` | High-level eBPF tracer | `sudo bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s\n", str(args->filename)); }'` |
| `linux-perf` | `perf` CLI (CPU profiling, syscalls) | `sudo perf top` |
| `sysstat` | iostat, pidstat, sar | `iostat -x 1` |
| `iotop` | Per-process IO view | `sudo iotop` |
| `iftop` | Per-host bandwidth | `sudo iftop -i eth0` |
| `nethogs` | Per-process bandwidth | `sudo nethogs eth0` |

### Docs & man pages

| Package | Purpose | Example |
|---|---|---|
| `manpages` | Base Unix man pages | `man 7 signal` |
| `manpages-dev` | C library/dev man pages | `man 2 open`, `man 3 printf` |
| `manpages-posix` | POSIX man pages | `man posix` |
| `manpages-posix-dev` | POSIX dev API | `man 3posix strcmp` |
| `info` | GNU Info reader | `info libc` |
| `texinfo` | Build Info docs | `makeinfo foo.texi` |
| `cppreference-doc-en-html` | Offline cppreference | open `/usr/share/cppreference/doc/html/index.html` |
| `python3-doc` | Python3 docs | `/usr/share/doc/python3-doc` |
| `linux-doc` | Linux kernel docs | `/usr/share/doc/linux-doc` |
| `gcc-doc` | GCC manual | `info gcc` |

### Shell / general utilities

| Package | Purpose | Example |
|---|---|---|
| `zsh` | Z shell | `zsh` |
| `zsh-autosuggestions` | Inline history suggestions | auto-sourced via `post/10-shell.sh` |
| `tmux` | Terminal multiplexer | `tmux new -s work` |
| `neovim` | Modern vim fork | `nvim file` |
| `vim` | Classic editor | `vim file` |
| `htop` | Process viewer | `htop` |
| `tree` | Directory tree | `tree -L 2` |
| `jq` | JSON CLI processor | `curl -s api/ | jq '.items[0]'` |
| `curl` | HTTP client | `curl -sSL https://example.com` |
| `wget` | Non-interactive downloader | `wget -c https://...` |
| `rsync` | Fast file sync | `rsync -avz src/ host:dest/` |
| `git` | Version control | `git status` |
| `git-lfs` | Large-file storage | `git lfs track '*.bin'` |
| `unzip` | Extract .zip | `unzip file.zip` |
| `p7zip-full` | Extract .7z and others | `7z x file.7z` |
| `zstd` | Fast compression | `zstd -19 file` |
| `ca-certificates` | Root CA bundle | updated by apt |
| `gnupg` | GPG signing/verification | `gpg --verify file.sig file` |
| `ccache` | Compiler cache | `export CC='ccache gcc'` |
| `direnv` | Per-directory env vars | `echo 'export X=1' > .envrc && direnv allow` |
| `entr` | Run on file change | `ls *.c | entr -c make` |
| `moreutils` | `sponge`, `ts`, `vidir`, `parallel` | `sort file | sponge file` |

### Docker engine

| Package | Purpose | Example |
|---|---|---|
| `docker-ce` | Docker engine | `docker run hello-world` |
| `docker-ce-cli` | Docker CLI | `docker ps` |
| `containerd.io` | OCI runtime | (used by docker) |
| `docker-buildx-plugin` | Multi-platform builds | `docker buildx build --platform linux/arm64 .` |
| `docker-compose-plugin` | Compose v2 | `docker compose up -d` |

### Offline doc viewer

| Package | Purpose | Example |
|---|---|---|
| `zeal` | Offline API-docs viewer | `zeal` |

---

## `pipx` — Python CLIs on PATH

| Package | Purpose | Example |
|---|---|---|
| `commitizen` | Conventional-commit helper | `cz commit` |
| `poetry` | Python dep / build tool | `poetry new myproj` |
| `pre-commit` | Git-hook framework | `pre-commit run --all-files` |
| `ipython` | Enhanced Python REPL | `ipython` |
| `ruff` | Fast Python linter + formatter | `ruff check .` |
| `black` | Python formatter | `black src/` |
| `mypy` | Python type checker | `mypy src/` |
| `uv` | Fast pip / venv replacement | `uv pip install foo` |
| `httpie` | Friendly HTTP CLI (`http`) | `http GET example.com` |
| `ropper` | ROP / gadget finder | `ropper --file ./bin --search 'pop rdi'` |
| `ROPgadget` | Alt. ROP gadget finder | `ROPgadget --binary ./bin` |
| `frida-tools` | Dynamic instrumentation CLI | `frida-trace -U -i open com.app` |
| `objection` | Frida-based runtime mobile tool | `objection -g com.app explore` |
| `mitmproxy` | Intercepting HTTPS proxy | `mitmproxy -p 8080` |
| `sslyze` | TLS server auditor | `sslyze example.com` |
| `volatility3` | Memory-image forensics (`vol`) | `vol -f mem.raw windows.info` |
| `yara` | YARA rules CLI | `yara rules.yar ./sample` |
| `impacket` | SMB/Kerberos scripts | `impacket-secretsdump domain/user@host` |
| `netexec` | Modern CrackMapExec replacement | `netexec smb 10.0.0.0/24 -u u -p p` |
| `pipreqs` | Generate requirements.txt | `pipreqs ./project` |

---

## `pip_system` — Python libraries (system-wide)

These are `import`-able from any `python3` shell (installed with
`--break-system-packages`).

| Package | Purpose | Example |
|---|---|---|
| `pwntools` | CTF / exploit-dev framework | `from pwn import *` |
| `capstone` | Python bindings for capstone | `from capstone import *` |
| `unicorn` | CPU emulator bindings | `from unicorn import Uc` |
| `keystone-engine` | Assembler bindings | `from keystone import Ks` |
| `lief` | ELF/PE/Mach-O parser | `import lief; b = lief.parse("bin")` |
| `r2pipe` | Drive radare2 from Python | `import r2pipe; r = r2pipe.open("bin")` |
| `rzpipe` | Drive rizin from Python | `import rzpipe; r = rzpipe.open("bin")` |
| `z3-solver` | SMT solver | `from z3 import *` |
| `yara-python` | YARA from Python | `import yara; r = yara.compile(...)` |
| `frida` | Frida Python bindings | `import frida` |
| `scapy` | Packet crafting | `from scapy.all import *` |
| `requests` | HTTP client | `import requests; requests.get(url)` |
| `requests-toolbelt` | Extras for requests (multipart uploads, etc.) | `from requests_toolbelt import MultipartEncoder` |

---

## `github_releases` — single-binary tools (latest releases)

### Daily-driver CLIs

| Repo | Installs as | Purpose | Example |
|---|---|---|---|
| `BurntSushi/ripgrep` | `rg` | Fast recursive grep | `rg -nF 'TODO' src/` |
| `sharkdp/fd` | `fd` | Modern `find` | `fd -e rs` |
| `sharkdp/bat` | `bat` | `cat` with syntax highlight | `bat src/main.rs` |
| `junegunn/fzf` | `fzf` | Fuzzy finder | `vim $(fzf)` |
| `dandavison/delta` | `delta` | Git diff pager | `git diff` (configure as core.pager) |
| `eza-community/eza` | `eza` | Modern `ls` | `eza -la --git` |
| `jesseduffield/lazygit` | `lazygit` | Terminal UI for git | `lazygit` |
| `cli/cli` | `gh` | GitHub CLI | `gh pr create` |
| `starship/starship` | `starship` | Cross-shell prompt | `eval "$(starship init zsh)"` |
| `atuinsh/atuin` | `atuin` | Magical shell history | auto-wired via `post/50-atuin-init.sh` |

### Recon / web testing

| Repo | Installs as | Purpose | Example |
|---|---|---|---|
| `projectdiscovery/nuclei` | `nuclei` | Template-based vuln scanner | `nuclei -u https://t -t cves/` |
| `projectdiscovery/httpx` | `pdhttpx` | HTTP probe (renamed to avoid clash with Python httpx) | `cat hosts.txt | pdhttpx` |
| `projectdiscovery/subfinder` | `subfinder` | Passive subdomain enum | `subfinder -d example.com` |
| `projectdiscovery/naabu` | `naabu` | Fast port scanner | `naabu -host 10.0.0.1` |
| `projectdiscovery/katana` | `katana` | Web crawler/spider | `katana -u https://t` |
| `OJ/gobuster` | `gobuster` | URL/DNS/VHost brute-forcer | `gobuster dir -u https://t -w words.txt` |
| `jpillora/chisel` | `chisel` | TCP/UDP tunnel over HTTP | `chisel server -p 8080 --reverse` |

### Secrets scanners

| Repo | Installs as | Purpose | Example |
|---|---|---|---|
| `trufflesecurity/trufflehog` | `trufflehog` | Secrets scanner across git history | `trufflehog git https://github.com/org/repo` |
| `gitleaks/gitleaks` | `gitleaks` | Git secrets scanner | `gitleaks detect -v` |

### Dev utilities

| Repo | Installs as | Purpose | Example |
|---|---|---|---|
| `casey/just` | `just` | Modern `make` alternative | `just build` |
| `watchexec/watchexec` | `watchexec` | Run on file change | `watchexec -e rs cargo test` |
| `sharkdp/hyperfine` | `hyperfine` | Benchmark CLI commands | `hyperfine 'sort file' 'rg . file'` |
| `jesseduffield/lazydocker` | `lazydocker` | Terminal UI for docker | `lazydocker` |

---

## `tarballs` — versioned directory installs

| Name | Installs to | Purpose | Example |
|---|---|---|---|
| `zig` | `/opt/zig/<version>` (symlinked `/usr/local/bin/zig`) | Zig compiler | `zig build-exe hello.zig` |
| `ghidra` | `/opt/ghidra/<version>` (symlinked `/usr/local/bin/ghidraRun`) | NSA reverse engineering suite | `ghidraRun` |

---

## `rustup` — Rust toolchain

| Item | Purpose | Example |
|---|---|---|
| Toolchain `stable` | Default stable Rust | `rustc --version` |
| Toolchain `nightly` | Nightly (unstable features) | `cargo +nightly build` |
| Component `rust-src` | Std library source (for rust-analyzer) | used by IDEs |
| Component `rust-analyzer` | LSP for Rust | launched by editor |
| Component `clippy` | Rust linter | `cargo clippy` |
| Component `rustfmt` | Rust formatter | `cargo fmt` |
| Component `llvm-tools-preview` | LLVM tools (cov-report, objdump) | `cargo llvm-cov` |
| Target `x86_64-unknown-linux-musl` | Static musl builds | `cargo build --target x86_64-unknown-linux-musl` |
| Target `wasm32-unknown-unknown` | WebAssembly | `cargo build --target wasm32-unknown-unknown` |

---

## `git_sources` — cloned repositories

### RE / exploit dev tooling

| Repo | Cloned to | Purpose | Example |
|---|---|---|---|
| `hugsy/gef` | `~/src/gef` | GDB Enhanced Features | auto-sourced from `~/.gdbinit` |
| `hugsy/gef-extras` | `~/src/gef-extras` | Extra gef commands/structs | wired into `~/.gef.rc` |
| `keystone-engine/keystone` | `~/src/keystone` | Builds `kstool` from source | `kstool x64 "mov rax, 0"` |
| `pwndbg/pwndbg` | `~/src/pwndbg` | Alt. gdb frontend | `cd ~/src/pwndbg && ./setup.sh` |
| `JonathanSalwan/ROPgadget` | `~/src/ROPgadget` | Source for ROPgadget (pipx version also installed) | `python3 ROPgadget.py --binary ./bin` |
| `angr/angr` | `~/src/angr` | Symbolic execution framework source | `pip install angr` in a venv |

### Wordlists / payloads / references

| Repo | Cloned to | Purpose | Example |
|---|---|---|---|
| `danielmiessler/SecLists` | `~/sec/SecLists` | Massive wordlist/payload collection | `hydra -L SecLists/.../users.txt ...` |
| `swisskyrepo/PayloadsAllTheThings` | `~/sec/PayloadsAllTheThings` | Attack payload cheatsheets | browse `~/sec/PayloadsAllTheThings/XSS Injection/` |
| `carlospolop/PEASS-ng` | `~/sec/PEASS-ng` | linpeas / winpeas privesc scripts | `bash PEASS-ng/linPEAS/linpeas.sh` |
| `GTFOBins/GTFOBins.github.io` | `~/sec/GTFOBins` | Abuse suid binaries cheat sheet | grep `_md/` files |
| `LOLBAS-Project/LOLBAS` | `~/sec/LOLBAS` | Windows living-off-the-land binaries | browse `yml/` files |
| `HackTricks-wiki/hacktricks` | `~/sec/hacktricks` | Pentest wiki offline | browse markdown files |

---

## `docker` — images (pulled, optionally saved to cache)

### Base language/runtime images

| Image | Purpose | Example |
|---|---|---|
| `debian:trixie` | Full Debian Trixie base | `docker run --rm -it debian:trixie bash` |
| `debian:trixie-slim` | Minimal Debian Trixie | `docker run --rm -it debian:trixie-slim bash` |
| `ubuntu:latest` | Latest Ubuntu LTS | `docker run --rm -it ubuntu bash` |
| `alpine:latest` | Minimal musl-based image | `docker run --rm -it alpine ash` |
| `python:3` | Full Python 3 toolchain | `docker run --rm -v "$PWD":/app python:3 bash` |
| `python:3-slim` | Slim Python 3 | same, smaller |
| `node:lts` | Node.js LTS | `docker run --rm -it node:lts node` |
| `golang:latest` | Go toolchain | `docker run --rm -v "$PWD":/app golang go build` |
| `rust:latest` | Rust toolchain | `docker run --rm -v "$PWD":/app rust cargo build` |
| `eclipse-temurin:21` | JDK 21 (recommended OpenJDK distro) | `docker run --rm -it eclipse-temurin:21 jshell` |

### Services

| Image | Purpose | Example |
|---|---|---|
| `redis:latest` | Redis server | `docker run --rm -p 6379:6379 redis` |
| `postgres:latest` | Postgres server | `docker run --rm -e POSTGRES_PASSWORD=x postgres` |
| `nginx:latest` | Nginx server | `docker run --rm -p 8080:80 nginx` |

### Security / offensive distros + tools

| Image | Purpose | Example |
|---|---|---|
| `kalilinux/kali-rolling:latest` | Kali base | `docker run --rm -it kalilinux/kali-rolling bash` |
| `remnux/remnux-distro:focal` | REMnux malware-analysis distro | `docker run --rm -it remnux/remnux-distro:focal bash` |
| `refirmlabs/binwalk:latest` | Latest binwalk (v3 Rust) | wrapped as `/usr/local/bin/binwalk` |
| `metasploitframework/metasploit-framework:latest` | Metasploit | `docker run --rm -it metasploitframework/metasploit-framework msfconsole` |
| `mitmproxy/mitmproxy:latest` | HTTPS intercepting proxy | `docker run --rm -it -p 8080:8080 mitmproxy/mitmproxy` |
| `owasp/zap2docker-stable:latest` | OWASP ZAP (legacy image name) | `docker run --rm -t owasp/zap2docker-stable zap-baseline.py -t https://t` |

### Intentionally vulnerable targets (practice only)

| Image | Purpose | Example |
|---|---|---|
| `bkimminich/juice-shop:latest` | OWASP Juice Shop (modern) | `docker run --rm -p 3000:3000 bkimminich/juice-shop` |
| `vulnerables/web-dvwa:latest` | Damn Vulnerable Web App | `docker run --rm -p 80:80 vulnerables/web-dvwa` |
| `webgoat/webgoat:latest` | OWASP WebGoat | `docker run --rm -p 8080:8080 webgoat/webgoat` |

---

## `docs`

| Setting | Purpose |
|---|---|
| `rebuild_mandb: true` | Re-index man pages after all apt installs |
| `rebuild_info: true` | Refresh `info` directory |
| `zeal_docsets: [C, C++, Rust, Python_3, Bash]` | Docsets auto-downloaded into Zeal |
