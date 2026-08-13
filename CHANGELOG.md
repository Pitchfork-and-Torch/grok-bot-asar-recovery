# Changelog

## v1.1.0 Refuse a broken restore (2026-10-01)

- The restore script reads the asar header before copying.
- A current archive that already lists `tree-sitter/package.json` with a size is left alone.
- Backups missing that file, and any file with `broken` in the name, are not restored.
- `-CheckOnly` reports the header and writes nothing.

## v1.0.0 (2026-08-13)

- Restore script and runbook for the empty `dist/deps` stub that hid `tree-sitter`.
