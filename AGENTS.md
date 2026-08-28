# Project Guidelines — src

This project follows the organization-wide [Z-Shell Organization Guidelines](https://github.com/z-shell/.github/blob/main/AGENTS.md).

## What this is

`src` contains the core Zi loader scripts, installer mechanisms, CDN assets,
and sync utilities.

## Branching

- This repository uses trunk-based development on `main` per organization ADR
  0019. Create short-lived branches from `main` and target pull requests to
  `main`.
- Use the organization branch names `feature-<id>`, `bug-<id>`, or
  `hotfix-<id>`.
- Keep `main` deployable; deployment remains a separately verified workflow
  result after merge.

## Conventions & Testing

- Language: Zsh and POSIX sh.
- Follow the canonical
  [shell dialect dispatcher](https://github.com/z-shell/.github/blob/main/.github/instructions/shell.instructions.md)
  and, for Zsh files, the
  [Zsh Scripting Standard](https://github.com/z-shell/.github/blob/main/.github/instructions/zsh-scripting.instructions.md).
- Verify installer and loader behavior with the repository test suite:

  ```sh
  sh ./tests/installers.sh
  ```
