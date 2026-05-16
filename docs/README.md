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
