# Proposed Changes (Next Phase)

## Feature: Interactive Asset Selection

- [x] Implement `-a` / `--all-assets` flag in `install` command.
- [x] Add interactive CLI menu to list all assets for a release (GitHub, GitLab, Codeberg).
- [x] Allow users to manually select an asset by number/name.

## Feature: Binary Aliasing

- [x] Implement `--as <name>` flag in `install` command.
- [x] Update `finalizeInstall` to use the provided alias as the final binary name.
- [x] Store the alias in `bin.yml` to maintain consistent identification.

## Feature: Cache Management

- [ ] Implement `bin clean` command.
- [ ] Add logic to delete all files in the `cache/` directory (temporary downloads and extractions).
- [ ] Output total space cleared to the user.

## Feature: API Information & Rate Limits

- [ ] Implement `bin info` command.
- [ ] Query GitHub/GitLab/Codeberg `/rate_limit` or similar endpoints.
- [ ] Display remaining quota and reset times for each provider.

## Feature: Visual Progress Bars

- [x] Explore minimalist ANSI escape sequence base progress bars for multi-threaded downloads.
- [x] If complexity is low, implement real-time percentage updates per thread.

## Documentation: Roadmap update

- [x] Add "Self-Update" to the future possibilities section in `README.md`.
