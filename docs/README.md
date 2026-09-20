<!-- markdownlint-disable MD041 -->
<div align="center">
  <a href="https://github.com/z-shell/zi">
    <img src="https://raw.githubusercontent.com/z-shell/.github/main/profile/img/logo.png" width="72" height="72" alt="Z-Shell logo">
  </a>

# Z-Shell source delivery

Installer, loader, setup planner, and CDN assets for [Zi](https://github.com/z-shell/zi).

[![Linux CI](https://img.shields.io/github/actions/workflow/status/z-shell/src/check-linux.yml?branch=main&label=linux&style=flat-square)](https://github.com/z-shell/src/actions/workflows/check-linux.yml)
[![macOS CI](https://img.shields.io/github/actions/workflow/status/z-shell/src/check-macos.yml?branch=main&label=macOS&style=flat-square)](https://github.com/z-shell/src/actions/workflows/check-macos.yml)
[![License](https://img.shields.io/github/license/z-shell/src?style=flat-square)](https://github.com/z-shell/src/blob/main/LICENSE)

</div>

## Install Zi

```sh
sh -c "$(curl -fsSL https://get.zshell.dev)" --
```

The default profile installs Zi and adds one short managed entry to the user's
Zsh startup file:

```zsh
# >>> zi setup >>>
source '/absolute/config/zi/setup.zsh'
# <<< zi setup <<<
```

> [!IMPORTANT]
> The generated `setup.zsh` owns startup sequencing, settings, and diagnostics.
> Read the [installation guide](https://wiki.zshell.dev/docs/getting_started/installation)
> before selecting another profile, branch, or install location.

## Published assets

| Endpoint                                                                               | Content                                          |
| :------------------------------------------------------------------------------------- | :----------------------------------------------- |
| [get.zshell.dev](https://get.zshell.dev)                                               | Standalone installer entrypoint                  |
| [init.zshell.dev](https://init.zshell.dev)                                             | Zi loader                                        |
| [src.zshell.dev](https://src.zshell.dev)                                               | Published source assets                          |
| [checksum.txt](https://raw.githubusercontent.com/z-shell/src/main/public/checksum.txt) | SHA-256 checksums for published installer assets |

`install.sh` remains the user-facing entrypoint. It downloads its companion
setup assets from the same source revision, verifies their checksums, creates a
reviewable plan, and applies the checkout and configuration as separate phases.
The `loader`, `annex`, and `zunit` profiles all use that planner. The `-i skip`
profile installs Zi without changing `.zshrc`.

## Repository layout

| Path                  | Purpose                                                                  |
| :-------------------- | :----------------------------------------------------------------------- |
| `public/sh/`          | POSIX shell installers, planner, checksum, and synchronization utilities |
| `public/setup/`       | Versioned profile data consumed by the planner                           |
| `public/zsh/`         | Zsh loader and reusable snippets                                         |
| `public/index.html`   | Landing page deployed with the public assets                             |
| `tests/installers.sh` | Cross-platform installer and loader behavior tests                       |

## Verify locally

```sh
sh tests/installers.sh
sh -n public/sh/*.sh
shellcheck public/sh/*.sh
```

Regenerate checksums after changing a published asset:

```sh
sh public/sh/generate-checksums.sh
git diff --exit-code -- public/checksum.txt
```

GitHub Actions exercises the installer and loader on Linux, macOS, and Cygwin.
Merges to `main` publish `public/` through GitHub Pages, and the loader-drift
workflow verifies that the deployed loader matches its source and checksum.

## Documentation and support

- [Z-Shell Wiki](https://wiki.zshell.dev/)
- [Zi installation guide](https://wiki.zshell.dev/docs/getting_started/installation)
- [Zi plugin manager](https://github.com/z-shell/zi)
- [Zsh Plugin Standard v2](https://wiki.zshell.dev/community/zsh_plugin_standard)
- [Zsh manual: startup and shutdown files](https://zsh.sourceforge.io/Doc/Release/Files.html)
- [Issue tracker](https://github.com/z-shell/src/issues)
- [Organization discussions](https://github.com/orgs/z-shell/discussions)
