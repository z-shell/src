<h1 align="center">
  <p>
    <a href="https://github.com/z-shell/zi">
      <img src="https://raw.githubusercontent.com/z-shell/.github/main/profile/img/logo.png" alt="Logo" width="80" height="80" />❮ Zi ❯
    </a>
  </p>
</h1>
<h3 align="center">
  <a href="https://github.com/orgs/z-shell/discussions/">《❔》Ask a Question </a>
  <a href="https://wiki.zshell.devv/search/">《💡》Search Wiki </a>
  <a href="https://github.com/z-shell/community/issues/new?assignees=&labels=%F0%9F%91%A5+member&template=membership.yml&title=team%3A+">《💜》Join </a>
  <a href="https://translate.zshell.dev">《🌐》Localize </a>
</h3>
<p align="center">
 <a target="_self" href="https://translate.zshell.dev">
    <img alt="Crowdin" align="center" src="https://badges.crowdin.net/e/f108c12713ee8526ac878d5671ad6e29/localized.svg" />
  </a>
  <a target="_self" href="https://www.gnu.org/licenses/gpl-3.0/">
    <img align="center" src="https://img.shields.io/badge/License-GPL%20v3-blue.svg" alt="Project License" />
  </a>
  <a target="_self" href="https://github.com/z-shell/zi-vim-syntax/">
    <img align="center" src="https://img.shields.io/badge/--019733?logo=vim" alt="VIM" />
  </a>
  <a target="_self" href="https://open.vscode.dev/z-shell/src/">
    <img align="center" src="https://img.shields.io/badge/--007ACC?logo=visual%20studio%20code&logoColor=ffffff" alt="Visual Studio Code" />
  </a></p><hr />

### Content

- Wiki Pages:
  - https://wiki.zshell.dev
- Loader:
  - https://init.zshell.dev
- Installer:
  - https://get.zshell.dev
- R2:
  - https://r2.zshell.dev
- IPFS:
  - https://ipfs.zshell.dev
- jsDeliver:
  - https://cdn.jsdelivr.net/gh/z-shell/src@main/

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
