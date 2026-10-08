# bin-zig - Effortless Binary Manager (Zig port)

A lightweight, cross-platform binary manager written in Zig — a port of
[marcosnils/bin](https://github.com/marcosnils/bin). It mirrors the reference's functionality:
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

`zig build test` runs the unit test suite (config, providers, checksum, cli,
assets, download, github, install, update).

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
      --debug        Enable debug mode
  -h, --help         help for bin
      --retries int  Extra attempts for a transfer that fails mid-flight (default 2)
      --timeout int  Seconds without data before aborting a transfer (default 30, 0 disables)
  -v, --version      version for bin
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

A bare compressed binary — an asset that is only a `.gz`, `.xz` or `.bz2`
executable rather than an archive — is installed under the asset name with the
compression extension dropped, so `bin install …/restic.xz` lands as `restic`.
Files extracted from an archive keep the name they have inside it.

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
bin update [binary_path...] [--dry-run] [-y] [-a] [-p] [-c] [-x binary...]
```

Checks for newer versions (semver-aware), asks for confirmation, then
re-installs. `--dry-run` exits with code 3 when updates are found, `-y` skips
the prompt, `-c` continues on error, `-a` shows every download option instead
of scoring, and `-p` skips path checking inside packages.

`-x, --exclude <binary>` (repeatable) leaves a binary alone. The value is a
name in `PATH` or a managed path, exactly like a positional argument; a value
that `bin` does not manage is an error rather than a silent no-op.

Unless `-a` is given, the artefact chosen on the previous install or upgrade is
re-selected automatically when exactly one candidate matches, so a normal
`bin update` does not ask which asset to take — `ensure` has always worked this
way.

Updating a binary that is currently running works: the file being replaced is
moved aside to `.{name}.old` next to it, and a later update reclaims it,
instead of failing with `Access is denied`.

### Other commands

- `bin ensure` re-installs binaries whose file is missing or whose SHA-256 no
  longer matches the stored hash (keeps the pinned state).
- `bin pin <name|path...>` / `bin unpin` — pinned binaries are skipped by
  `update` (unless explicitly listed).
- `bin prune [-f]` removes config entries for binaries missing from disk
  (asks for confirmation unless `-f`).
- `bin remove <name|path...>` removes the binary and its config entry.
- `bin clean` clears the download cache (the `cache` directory next to the
  configured download path) — a zig extension.
- `bin info` prints the GitHub, GitLab and Codeberg API rate limits, using the
  usual auth tokens — a zig extension.

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
- Updating a binary that is still running (never upstreamed): the file being
  replaced is moved to `.{name}.old` first, and Windows refuses to rename onto
  that sibling while it is still the running image — so a second `bin update`
  died with `Access is denied`. That is a sharing violation rather than a
  permission one, which is why running from an elevated shell never helped. A
  `.old` that cannot be removed is now stepped over as `.{name}.old.<n>` and
  reclaimed by a later update; the reference aborts in that situation.
- `clean` and `info` are zig extensions (not present in the reference).
- `bzip2`-compressed releases require a `bzip2` binary on PATH (the Zig std
  library dropped bzip2 in 0.15).
- Transfers have a deadline. The reference blocks on the socket forever when a
  peer stops sending data mid-transfer (no output, no error); here a transfer
  that receives nothing for `--timeout <seconds>` (default 30, `0` disables,
  or `BIN_TIMEOUT`) is retried up to `--retries <n>` extra times (default 2,
  `BIN_RETRIES`) with a small backoff. Each attempt runs on its own thread and a
  stalled one is *given up on* rather than waited for, then retried on a fresh
  connection — which is what makes the retry work on Windows too, where a blocked
  Winsock receive cannot be woken from another thread. Because of that, an
  abandoned attempt can still be inside the HTTP client, so clients (and the
  stalled attempt's thread, parked in the kernel) live until `bin` exits.

## Versioning

Releases are tagged `vX.Y.Z`, starting at **v1.0.0** — the port matches the
reference's feature set (marcosnils/bin v0.29.3, plus the v0.29.4 install and
update fixes #312 and #313) and the fixes listed above, so it is no longer a
moving `dev` build. `bin -v/--version` prints the version from
`src/version.zig`; bump that and `.version` in `build.zig.zon` together.

## License

MIT
