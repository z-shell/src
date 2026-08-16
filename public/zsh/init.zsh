#!/usr/bin/env zsh
# -*- mode: zsh; sh-indentation: 2; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: ft=zsh sw=2 ts=2 et
#
# Zi Loader — bootstrap and source the Zi plugin manager.
#
# Sourced early in .zshrc. Defines zzinit() which clones Zi on first run,
# sources zi.zsh, registers completions, and loads zpmod if built.
# All helper functions are cleaned up after zzinit() returns.

# ── Zi Configuration ──────────────────────────────────────────────────────────

typeset -ghA ZI

# https://wiki.zshell.dev/docs/guides/customization
: "${ZI[REPOSITORY]:=https://github.com/z-shell/zi.git}"
: "${ZI[STREAM]:=main}"
: "${ZI[HOME_DIR]:=${XDG_DATA_HOME:-$HOME/.local/share}/zi}"
: "${ZI[BIN_DIR]:=${ZI[HOME_DIR]}/bin}"
: "${ZI[CACHE_DIR]:=${XDG_CACHE_HOME:-$HOME/.cache}/zi}"
: "${ZI[CONFIG_DIR]:=${XDG_CONFIG_HOME:-$HOME/.config}/zi}"

# https://wiki.zshell.dev/community/zsh_plugin_standard#global-parameter-with-prefix
: "${ZPFX:=${ZI[HOME_DIR]}/polaris}"
: "${ZI[ZMODULES_DIR]:=${ZI[HOME_DIR]}/zmodules}"
: "${ZI[ZCOMPDUMP_PATH]:=${ZI[CACHE_DIR]}/.zcompdump}"
: "${ZI[MUTE_WARNINGS]:=0}"

# History defaults
: "${HISTFILE:=${XDG_STATE_HOME:-$HOME/.local/state}/zsh/history}"
[[ -e "$HISTFILE" ]] || { command mkdir -p "${HISTFILE:h}"; command touch "$HISTFILE"; }
[[ -w "$HISTFILE" ]] && typeset -gx SAVEHIST=440000 HISTSIZE=441000

# ── Bootstrap Helpers ─────────────────────────────────────────────────────────

# Fetch content from a URL to stdout.
_zi_fetch() {
  builtin emulate -L zsh
  if (( $+commands[curl] )); then
    command curl -fsSL "$1"
  elif (( $+commands[wget] )); then
    command wget -qO- "$1"
  else
    return 255
  fi
}

# Clone Zi repository if it doesn't exist.
_zi_setup() {
  builtin emulate -L zsh
  builtin autoload colors; colors
  local -a git_refs
  local tmp_dir show_process process_url

  if [[ ! -f "${ZI[BIN_DIR]}/zi.zsh" ]]; then
    tmp_dir="${TMPDIR:-/tmp}/zi"
    [[ -d "$tmp_dir" ]] || command mkdir -p "$tmp_dir"

    show_process="${tmp_dir}/git-process.zsh"
    process_url="https://raw.githubusercontent.com/z-shell/zi/main/public/zsh/git-process-output.zsh"

    if [[ ! -f "$show_process" ]]; then
      if _zi_fetch "$process_url" > "${tmp_dir}/git-process.zsh"; then
        command chmod a+x "${tmp_dir}/git-process.zsh"
      else
        return 1
      fi
    fi

    (( $+commands[clear] )) && command clear
    builtin print -P "%F{33}▓▒░ %F{160}Installing interactive & feature-rich plugin manager (%F{33}z-shell/zi%F{160})%f%b…\n"
    command mkdir -p "${ZI[BIN_DIR]}" && \
      command git clone --verbose --progress --branch \
        "${ZI[STREAM]}" "${ZI[REPOSITORY]}" "${ZI[BIN_DIR]}" \
        |& { command "$show_process" || command cat; }

    if [[ -f "${ZI[BIN_DIR]}/zi.zsh" ]]; then
      command chmod -R go-w "${ZI[HOME_DIR]}"
      git_refs=("${(f@)$(builtin cd -q "${ZI[BIN_DIR]}" && command git log --color --graph --abbrev-commit \
        --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' | command head -5)}")
      builtin print
      builtin print -P "%F{33}▓▒░ %F{34}Successfully installed %F{160}(%F{33}z-shell/zi%F{160})%f%b\n"
      builtin print -rl -- "${git_refs[@]}"
    else
      builtin print -P "%F{160}▓▒░  The clone has failed…%f%b"
      builtin print -P "%F{160}▓▒░ %F{33} Please report the issue: %F{226}https://github.com/z-shell/zi/issues/new%f%b"
      return 1
    fi
  fi
  return 0
}

# Source zi.zsh, bootstrapping first if needed.
_zi_source() {
  builtin emulate -L zsh
  if [[ -f "${ZI[BIN_DIR]}/zi.zsh" ]]; then
    builtin source "${ZI[BIN_DIR]}/zi.zsh"
  else
    _zi_setup || return 1
    # Guard: if setup succeeded but zi.zsh is still missing, don't recurse
    if [[ -f "${ZI[BIN_DIR]}/zi.zsh" ]]; then
      builtin source "${ZI[BIN_DIR]}/zi.zsh"
    else
      return 1
    fi
  fi
}

# Load zpmod module if built.
_zi_pmod() {
  builtin emulate -L zsh
  if [[ -f "${ZI[ZMODULES_DIR]}/zpmod/Src/zi/zpmod.so" ]]; then
    module_path+=( "${ZI[ZMODULES_DIR]}/zpmod/Src" )
    zmodload zi/zpmod 2>/dev/null
  fi
  return 0
}

# Register Zi completion if the completion system is active.
_zi_comps() {
  builtin emulate -L zsh
  if (( ${+_comps} )); then
    (( ${+_comps[zi]} )) || _comps[zi]=_zi
  fi
  return 0
}

# ── Entry Point ───────────────────────────────────────────────────────────────

zzinit() {
  {
    _zi_source && _zi_comps && _zi_pmod
  } always {
    unset -f _zi_fetch _zi_setup _zi_source _zi_comps _zi_pmod zzinit 2>/dev/null
  }
}
