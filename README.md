# bin-zig - Effortless Binary Manager (Zig port)

A lightweight, fast, cross-platform binary manager written in Zig. This project is a port of the original [marcosnils/bin](https://github.com/marcosnils/bin) projects, aimed at providing the same convenience with zero dependencies and high performance.

## 🚀 Features

- **Multi-Provider Support**: Fully integrated with **GitHub**, **GitLab**, and **Codeberg**.
- **Ultra-Fast Transfers**: Multi-threaded downloader using HTTP range requests.
- **Security First**: Automatic SHA256 integrity verification for all downloads.
- **Smart Asset Selection**: Automatically detects OS and Architecture to find the best match.
- **Native Extraction**: In-binary support for `.zip`, `.tar.gz`, `.tar.xz`, `.tar.zst`, and `.tar.lzma`.
- **Full Lifecycle**: Commands to `list`, `update`, `remove`, `ensure`, and `pin` binaries.

## 📦 Installation

### Build using Just

If you have [just](https://github.com/casey/just) installed:

```bash
# 1. Bootstrap Zig (if not already installed)
just install-zig

# 2. Build optimized binary
just build
```

> **Note**: You MUST have Zig installed or bootstrapped via the command above before attempting to build the project.

### Build from source (Manual)

Ensure you have [Zig](https://ziglang.org/download/) installed (0.16.0-dev or later recommended).

```bash
git clone https://github.com/user/bin-zig
cd bin-zig
zig build -Doptimize=ReleaseSafe
```

The executable will be located in `zig-out/bin/bin`.

## 📚 Commands Reference

| Command                     | Description                                | Example                                  |
| --------------------------- | ------------------------------------------ | ---------------------------------------- |
| `bin install <url>`         | Install binary with optional alias/assets  | `bin install cli/cli --as gh -a`         |
| `bin list`                  | List installed binaries and versions       | `bin list`                               |
| `bin update`                | Check all binaries for available updates   | `bin update`                             |
| `bin update <name>`         | Update a specific binary                   | `bin update gh`                          |
| `bin update --all`          | Update all managed binaries                | `bin update --all`                       |
| `bin remove <name>`         | Remove a managed binary (works with .exe)  | `bin remove gh`                          |
| `bin ensure`                | Reinstall any missing binaries             | `bin ensure`                             |
| `bin pin <name>`            | Lock binary to its current version         | `bin pin fzf`                            |
| `bin unpin <name>`          | Unlock binary for updates                  | `bin unpin fzf`                          |
| `bin prune`                 | Remove dead entries from configuration     | `bin prune`                              |
| `bin clean`                 | Clear download/extraction cache            | `bin clean`                              |

**Tip**: You can install specific versions using the `@` syntax: `bin install github.com/cli/cli@v2.40.1`.

## 🔧 Configuration

Settings are stored in `~/.config/bin.yml`.

```yaml
bin_dir: C:\Utilities\exe
download_threads: 4
tokens:
  github: your_github_token
  gitlab: your_gitlab_token
  codeberg: your_codeberg_token
```

## 📁 Default Locations

If `bin_dir` is not specified in your config:

- **Windows**: `%LOCALAPPDATA%\bin` (e.g., `C:\Users\Name\AppData\Local\bin`)
- **Linux/macOS**: `~/.local/bin`

## 🔮 Future Possibilities

- **Self-Update**: A command to automatically update `bin-zig` to the latest version.
- **Rollback**: Support for rolling back to previously installed versions.

## 📄 License

This project is licensed under the MIT License.
