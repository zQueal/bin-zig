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
| `bin install <url> [path]` | Install binary from GitHub, GitLab, or Codeberg  | `bin install cli/cli --as gh -a`         |
| `bin list`                  | List installed binaries and versions       | `bin list`                               |
| `bin update <name...>`      | Update specific binaries                   | `bin update gh kubectl`                 |
| `bin update --all`          | Update all managed binaries                | `bin update --all`                       |
| `bin remove <name...>`      | Remove managed binaries (works with .exe)  | `bin remove gh kubectl fzf`              |
| `bin ensure`                | Reinstall any missing binaries             | `bin ensure`                             |
| `bin pin <name...>`         | Lock binaries to their current version    | `bin pin terraform kubectl`              |
| `bin unpin <name...>`       | Unlock binaries for updates                | `bin unpin terraform kubectl`            |
| `bin info`                  | Show API rate limit information            | `bin info`                               |
| `bin prune`                 | Remove dead entries from configuration     | `bin prune`                              |
| `bin clean`                 | Clear download/extraction cache            | `bin clean`                              |
| `bin help [command]`       | Show help for any command                     | `bin help install`                          |

**Tip**: You can install specific versions using the `@` syntax: `bin install github.com/cli/cli@v2.40.1`.

**Multiple Operations**: You can perform operations on multiple binaries at once:

```bash
# Remove multiple binaries
bin remove gh kubectl fzf

# Pin multiple binaries
bin pin terraform kubectl

# Update multiple binaries
bin update gh kubectl

# Unpin multiple binaries
bin unpin terraform kubectl
```

The commands will process all binaries and report a summary of successes and failures. If all operations fail, an error is returned. If some succeed and some fail, a warning is displayed.

## 🚩 Flags Reference

### Install Command Flags

| Flag            | Arguments | Description |
| --------------- | --------- | ----------- |
| `--as`          | `<name>`  | Install the binary with a custom alias name instead of using the repository name |
| `-a`            | -         | Interactive mode - prompts you to manually select from available assets when multiple are found |
| `--all-assets`  | -         | Same as `-a` - interactive mode for asset selection |
| `--provider`    | `<type>`  | Explicitly specify provider: github, gitlab, or codeberg |

**URL Formats**:
You can use three different URL formats when installing:

1. **Full URL** (auto-detects provider):
   ```bash
   bin install https://github.com/cli/cli
   bin install https://gitlab.com/gitlab-org/cli
   bin install https://codeberg.org/mergiraf/mergiraf
   ```

2. **Domain format** (auto-detects provider):
   ```bash
   bin install github.com/cli/cli
   bin install gitlab.com/gitlab-org/cli
   bin install codeberg.org/mergiraf/mergiraf
   ```

3. **Short format** (defaults to GitHub):
   ```bash
   bin install cli/cli
   ```

4. **Short format with explicit provider**:
   ```bash
   bin install --provider gitlab gitlab-org/cli
   bin install --provider codeberg mergiraf/mergiraf
   ```

**Custom Install Path**:
You can specify a custom installation directory (absolute or relative):

```bash
# Absolute path
bin install cli/cli /usr/local/bin/gh

# Relative path (converted to absolute)
bin install cli/cli ~/bin/gh
bin install cli/cli ./bin/gh
```

> **Note**: The install path must exist and be writable. The directory will NOT be created automatically.

**When to use `-a` (Interactive Asset Selection)**:
- By default, `bin-zig` automatically selects the best matching asset based on your OS and architecture
- Use `-a` when you want to manually choose a different asset (e.g., a different architecture, build variant, or special distribution)
- This is particularly useful when:
  - Multiple build variants are available (e.g., static vs dynamic linking)
  - You need a specific architecture (e.g., musl vs glibc on Linux)
  - The automatic selection doesn't pick the asset you want

**Example**:
```bash
# Install GitHub CLI as 'gh' and interactively select the asset
bin install cli/cli --as gh -a
```

### Update Command Flags

| Flag        | Arguments | Description |
| ----------- | --------- | ----------- |
| `--all`     | -         | Update all managed binaries to their latest available versions |

### Global Flags

| Flag               | Arguments | Description |
| ------------------ | --------- | ----------- |
| `-h`               | -         | Display help information and exit |
| `--help`           | -         | Same as `-h` |
| `-v`               | -         | Output version information and exit |
| `--version`        | -         | Same as `-v` |

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
