# bin-zig - Effortless Binary Manager (Zig port)

A lightweight, cross-platform binary manager written in Zig — a port of
[marcosnils/bin](https://github.com/marcosnils/bin). It mirrors the references functionality:
the same commands, flags, JSON config format and providers, built with zero
runtime dependencies and Zig 0.15.2.

## Requirements

- [Zig](https://ziglang.org/download/) **0.15.2 or later** (the code targets
  the 0.15.2 std library; newer 0.15.x patches work, 0.16+ is not supported).

## Build

```bash
# Windows / macOS / Linux
zig build -Doptimize=ReleaseSafe        # binary at zig-out/bin/bin

# cross-compile to Linux from anywhere
zig build -Dtarget=x86_64-linux
zig build -Dtarget=aarch64-linux
```

`zig build test` runs the unit test suite (config, providers, assets, checksum).

On Windows you can also use `just install-zig` to fetch Zig 0.15.2 and
`just build`.

## Usage

```
bin [command]

Commands:
  ensure    Ensures that all binaries listed in the configuration are present
  install   Installs the specified binary from a url
  list      List binaries managed by bin
  pin       Pins current version of the binaries
  prune     Prunes binaries that no longer exist in the system
  remove    Removes binaries managed by bin
  unpin     Unpins current version of the binaries
  update    Updates one or multiple binaries managed by bin
  clean     Clears the download cache (zig extension)
  info      Shows API rate limit information (zig extension)

Flags:
      --debug   Enable debug mode
  -h, --help    help for bin
  -v, --version version for bin
```

Running `bin` with no arguments lists the managed binaries. Aliases match the
reference: `install`/`i`, `update`/`u`, `ensure`/`e`, `list`/`ls`,
`remove`/`rm`.

### install

```
bin install <url> [name | path] [-f] [-a] [-p provider] [-n pattern]
```

- `-f, --force` overwrite the file if it already exists
- `-a, --all` show all possible download options (skip scoring & filtering)
- `-p, --provider` force a specific provider (github, gitlab, codeberg,
  hashicorp, helm, goinstall, docker)
- `-n, --name` glob pattern selecting a specific asset (use `asset/file` to
  select inside archives)

The second argument is a file name (joined with the default download path) or
a path. Supported URL forms:

```bash
bin install https://github.com/cli/cli
bin install github.com/junegunn/fzf
bin install gitlab.com/gitlab-org/cli
bin install codeberg.org/mergiraf/mergiraf
bin install releases.hashicorp.com/terraform
bin install get.helm.sh/helm-v3.16.3-linux-amd64.tar.gz
bin install goinstall://github.com/charmbracelet/glow
bin install docker://hashicorp/terraform
```

Specific versions can be pinned with an `@tag` suffix
(`bin install github.com/junegunn/fzf@v0.70.0`) — unlike the reference, the
`@tag` is parsed out of the repo name so updates keep working (the
"breaking updates" fix).

### update

```
bin update [binary_path...] [--dry-run] [-y] [-a] [-p] [-c] [-x pattern...]
```

Checks for newer versions (semver-aware), asks for confirmation, then
re-installs. `--dry-run` exits with code 3 when updates are found, `-y` skips
the prompt, `-c` continues on error, `-x` excludes binaries.

### Other commands

- `bin ensure` re-installs binaries whose file is missing or whose SHA-256 no
  longer matches the stored hash (keeps the pinned state).
- `bin pin <name|path...>` / `bin unpin` — pinned binaries are skipped by
  `update` (unless explicitly listed).
- `bin prune [-f]` removes config entries for binaries missing from disk
  (asks for confirmation unless `-f`).
- `bin remove <name|path...>` removes the binary and its config entry.

## Configuration

The configuration is JSON, byte-compatible with the reference implementation:

```json
{
    "default_path": "/home/user/.local/bin",
    "bins": {
        "/home/user/.local/bin/gh": {
            "path": "/home/user/.local/bin/gh",
            "remote_name": "gh",
            "version": "v2.40.0",
            "hash": "ae2a4e100870f9798359c035f6338add9e5dcc727545e7daa110acfa4a03e979",
            "url": "github.com/cli/cli",
            "provider": "github",
            "package_path": "bin/gh",
            "selected_asset": "gh_2.40.0_linux_amd64.tar.gz",
            "pinned": false
        }
    }
}
```

Resolution order (same as the reference):

1. `BIN_CONFIG` environment variable (the file must exist)
2. `$HOME/.bin/config.json` (legacy location)
3. `$XDG_CONFIG_HOME/bin/config.json` when `XDG_CONFIG_HOME` is set
4. `$HOME/.config/bin/config.json` when `$HOME/.config` exists
5. default `$HOME/.bin/config.json`

On first run the default download path is auto-detected from the first
writable directory in `PATH` (interactively picked, or prompted for manually).
Paths in the config may contain `$VAR`/`${VAR}` expansions.

Auth tokens are read from the environment (same names as the reference):
`GITHUB_TOKEN` (or `GITHUB_AUTH_TOKEN`), `GITLAB_TOKEN` (plus
`GITLAB_TOKEN_<hostname>` for self-hosted), `CODEBERG_TOKEN`, and the GHES
triple `GHES_BASE_URL`/`GHES_UPLOAD_URL`/`GHES_AUTH_TOKEN`.

## Providers

- **github** — release assets; `?filter=` glob over release tags supported
- **gitlab** — project packages, release asset links and release-description
  links; self-hosted instances via the URL hostname
- **codeberg** — Gitea/Forgejo releases; self-hosted instances supported
- **hashicorp** — `releases.hashicorp.com` (semver-aware latest)
- **helm** — `get.helm.sh` (static platform matrix)
- **goinstall** — builds a Go module via `go install module@version`
- **docker** — `docker://` images; installs a wrapper script that runs the
  image with the current directory mounted (the pull shells out to the
  `docker` CLI rather than the daemon SDK)

## Notes vs. the reference

- The update bug fixed here (never upstreamed): `user/repo@tag` URLs no longer
  break `bin update` — the tag is split from the repo with the *last* `@`, and
  short/domain/full URL forms all round-trip correctly.
- `clean` and `info` are zig extensions (not present in the reference).
- `bzip2`-compressed releases require a `bzip2` binary on PATH (the Zig std
  library dropped bzip2 in 0.15).

## License

MIT
