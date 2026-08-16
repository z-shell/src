# Project Guidelines — src

This project follows the organization-wide [Z-Shell Organization Guidelines](https://github.com/z-shell/.github/blob/main/AGENTS.md).

## What this is

`src` contains the core Zi loader scripts, installer mechanisms, CDN assets, and sync utilities.

## Conventions & Testing

- Language: Zsh and POSIX sh.
- Follow `.github/instructions/zsh-scripting.instructions.md`.
- Verify installer and loader behavior with the test suite:
  ```bash
  make test || ./tests/run.sh
  ```
