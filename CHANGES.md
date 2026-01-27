# Proposed Changes (Next Phase)

## Feature: Cache Management ✅ COMPLETED

- [x] Implement `bin clean` command.
- [x] Add logic to delete all files in the `cache/` directory (temporary downloads and extractions).
- [x] Output total space cleared to the user.

## Feature: API Information & Rate Limits ✅ COMPLETED

- [x] Implement `bin info` command.
- [x] Query GitHub/GitLab/Codeberg `/rate_limit` or similar endpoints.
- [x] Display remaining quota and reset times for each provider.
