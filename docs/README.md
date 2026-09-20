<!-- markdownlint-disable MD041 -->
<table style="background-color:transparent;">
  <tr>
    <td>
      <h1 align="center">
        <a target="_self" href="https://github.com/z-shell/zi">
          <img style="width: 60px; height: 60px"
            src="https://raw.githubusercontent.com/z-shell/zi/main/docs/images/logo.svg" alt="❮ Zi ❯ Logo" />
        </a>❮ <strong>Src</strong> ❯
      </h1>
      <h2 align="center">
        ✨ Z-Shell source library — snippets, installer scripts and shared utilities
      </h2>
      <div align="center">
        <a href="https://github.com/orgs/z-shell/discussions/"><strong>《 Ask a Question 》</strong></a>
        ·
        <a href="https://wiki.zshell.dev/search"><strong>《💡》Search Wiki </strong></a>
        ·
        <a
          href="https://github.com/z-shell/community/issues/new?assignees=&labels=%F0%9F%91%A5+member&template=membership.yml&title=team%3A+"><strong>《💜》Join
          </strong></a>
        ·
        <a href="https://translate.zshell.dev/"><strong>《🌐》Localize </strong></a>
      </div>
  </tr>
  </td>
  <tr>
    <td>
      <div align="center">
        <a title="Crowdin" target="_self" href="https://translate.zshell.dev/">
          <img align="center" src="https://badges.crowdin.net/e/f108c12713ee8526ac878d5671ad6e29/localized.svg" alt="Crowdin Status" />
        </a>
        <a title="License" target="_self" href="https://www.gnu.org/licenses/gpl-3.0/">
          <img align="center" src="https://img.shields.io/badge/License-GPL%20v3-blue.svg" alt="Project License" />
        </a>
        <a title="VIM" target="_self" href="https://github.com/z-shell/zi-vim-syntax/">
          <img align="center" src="https://img.shields.io/badge/--019733?logo=vim" alt="VIM" />
        </a>
        <a target="_self" href="https://open.vscode.dev/z-shell/src/">
          <img align="center" src="https://img.shields.io/badge/--007ACC?logo=visual%20studio%20code&logoColor=ffffff"
            alt="Visual Studio Code" />
        </a>
      </div>
  </tr>
  </td>
</table>
<hr />

### Content

- **Wiki Pages**: [wiki.zshell.dev](https://wiki.zshell.dev)
- **Loader**: [init.zshell.dev](https://init.zshell.dev)
- **Installer**: [get.zshell.dev](https://get.zshell.dev)
- **jsDeliver CDN**: [cdn.jsdelivr.net/gh/z-shell/src@main/](https://cdn.jsdelivr.net/gh/z-shell/src@main/)

### Guided setup

`public/sh/install.sh` now delegates installation to the POSIX `sh` setup planner. The default `loader` profile writes a reviewable plan, applies the Zi checkout as one phase, and applies loader configuration as a separate phase. The `annex` and `zunit` profiles add pinned recipes that run on the first shell start.

For a normal installation, run:

```sh
sh -c "$(curl -fsSL https://get.zshell.dev)"
```

The downloaded `install.sh` remains the only entry point; it retrieves and
verifies its planner assets automatically. To install an exact source revision,
use the same tag, branch, or commit for the script and `ZI_SRC_REF`:

```sh
ref=v1.2.3
curl -fsSL "https://raw.githubusercontent.com/z-shell/src/${ref}/public/sh/install.sh" |
  ZI_SRC_REF="${ref}" sh
```

To inspect and apply a plan manually:

```sh
sh public/sh/setup.sh plan --plan /tmp/zi-setup-plan --profile loader
plan_sha="$(cat /tmp/zi-setup-plan/plan.id)"
sh public/sh/setup.sh apply --plan /tmp/zi-setup-plan --phase checkout --expect "${plan_sha}"
sh public/sh/setup.sh apply --plan /tmp/zi-setup-plan --phase files --expect "${plan_sha}"
```

The files phase manages `init.zsh`, `setup.zsh`, `setup/pre.zsh`, `setup/shell.zsh`, and a marked `.zshrc` block. The user-facing block stays intentionally short:

```zsh
# >>> zi setup >>>
source '/home/you/.config/zi/setup.zsh'
# <<< zi setup <<<
```

The generated `setup.zsh` entrypoint owns the startup sequence and diagnostics. The files phase validates every recorded target before writing any target. A symlinked `.zshrc`, an externally changed managed block, an unrecognized Zi startup block, or checkout drift is refused with remediation output instead of being overwritten.

### Loader configuration

`public/zsh/init.zsh` defines `zzinit()`. Sourcing the file only declares the
function and applies defaults; nothing is cloned, sourced, or written until
`zzinit` is called.

The loader owns only the settings that must exist before Zi does:

| Setting             | Default                                   | Purpose                  |
| ------------------- | ----------------------------------------- | ------------------------ |
| `ZI[REPOSITORY]`    | `https://github.com/z-shell/zi.git`       | Clone source             |
| `ZI[STREAM]`        | `main`                                    | Branch or tag to clone   |
| `ZI[HOME_DIR]`      | Legacy home, otherwise XDG data `zi` root | Working-directory root   |
| `ZI[BIN_DIR]`       | `${ZI[HOME_DIR]}/bin`                     | Where `zi.zsh` is cloned |
| `ZI[MUTE_WARNINGS]` | `0`                                       | Loader warning control   |

The loader mirrors Zi core's home-resolution contract because it must find or
clone `zi.zsh` before core can run. An explicit `ZI[HOME_DIR]` wins. A
recognized legacy `$HOME/.zi` installation stays active. Otherwise the loader
uses `${XDG_DATA_HOME}/zi` when `XDG_DATA_HOME` is absolute, or
`$HOME/.local/share/zi` when it is unset, empty, or relative. When both homes
contain Zi data, an explicit or unique existing `BIN_DIR` identity selects the
matching home; otherwise the conservative fallback is the legacy home. No
automatic move or merge occurs.

`ZI[CACHE_DIR]`, `ZI[CONFIG_DIR]`, and every other Zi path are owned and
derived by `zi.zsh`. Set one in `.zshrc` before sourcing the loader to override
it; do not add a duplicate default to the loader. See the
[customization guide](https://wiki.zshell.dev/docs/guides/customization#customizing-paths).

One loader-only toggle exists:

| Setting              | Default | Purpose                                                    |
| -------------------- | ------- | ---------------------------------------------------------- |
| `ZI[LOADER_HISTORY]` | `1`     | Set to `0` to leave `HISTFILE`/`SAVEHIST`/`HISTSIZE` alone |

### Maintainer — Verify and Sync Loader

Check whether the local `public/zsh/init.zsh` matches the canonical GitHub raw `main` copy:

```sh
sh public/sh/sync-init.sh
```

Replace the local file if it drifts:

```sh
sh public/sh/sync-init.sh --write
```

Run against local fixtures (no network required, useful in tests):

```sh
sh public/sh/sync-init.sh \
  --local  /tmp/my-init.zsh \
  --remote /tmp/remote-init.zsh \
  --checksum-url /tmp/checksum.txt
```

Skip checksum validation:

```sh
sh public/sh/sync-init.sh --no-checksum
```

---

> This repository is compatible with [Zi](https://github.com/z-shell/zi)
