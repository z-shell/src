#!/usr/bin/env zsh
# -*- mode: zsh; sh-indentation: 2; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: ft=zsh sw=2 ts=2 et
#
# Zi Loader — bootstrap and source the Zi plugin manager.
#
# Execution profile: startup-file. This is sourced early in .zshrc and
# deliberately makes phase-owned global effects; it is not a caller-preserving
# sourced library.
#
# Sourcing this file only defines zzinit(). Nothing is cloned, sourced, or
# written until zzinit() is called:
#
#   if [[ -n ${XDG_CONFIG_HOME:-} && $XDG_CONFIG_HOME == /* ]]; then
#     ZI_LOADER_CONFIG_HOME="$XDG_CONFIG_HOME/zi"
#   else
#     ZI_LOADER_CONFIG_HOME="$HOME/.config/zi"
#   fi
#   if [[ -r "$ZI_LOADER_CONFIG_HOME/init.zsh" ]]; then
#     source "$ZI_LOADER_CONFIG_HOME/init.zsh" && zzinit
#   fi
#   unset ZI_LOADER_CONFIG_HOME
#
# Documented global effects of zzinit():
#   - sources zi.zsh, which owns its own documented global effects
#   - registers the zi completion in _comps when compinit has already run
#   - appends to module_path and loads zi/zpmod when the module is built
#   - on first run, clones ZI[REPOSITORY] into ZI[BIN_DIR]
#   - unsets its own helper functions on success
#
# All helper functions and zzinit() itself are removed after a successful run.
# On failure they are kept so the user can read the diagnostics and retry.

# ── Zi Configuration ──────────────────────────────────────────────────────────

typeset -ghA ZI

# Settings this loader must know before Zi exists, because they decide what to
# clone and where. See https://wiki.zshell.dev/docs/guides/customization
: "${ZI[REPOSITORY]:=https://github.com/z-shell/zi.git}"
: "${ZI[STREAM]:=main}"

# The loader needs HOME_DIR and BIN_DIR before Zi exists so it knows where to
# find or clone zi.zsh. Mirror Zi's home-resolution contract exactly, without
# creating directories: explicit values win, a recognized legacy home stays
# active, and fresh installs use an absolute XDG data base or its fallback.
# Cache and config remain unset here and are resolved by zi.zsh itself.
() {
  builtin emulate -L zsh

  local data_base legacy_home xdg_home marker requested_bin="${ZI[BIN_DIR]}"
  integer legacy_present=0 xdg_present=0

  if [[ -n $XDG_DATA_HOME && $XDG_DATA_HOME == /* ]]; then
    data_base="$XDG_DATA_HOME"
  else
    data_base="${HOME}/.local/share"
  fi
  legacy_home="${HOME}/.zi"
  xdg_home="${data_base}/zi"

  if [[ -z ${ZI[HOME_DIR]} ]]; then
    for marker in bin/zi.zsh plugins snippets completions zmodules; do
      if [[ -e "${legacy_home}/${marker}" ]]; then
        legacy_present=1
        break
      fi
    done
    for marker in bin/zi.zsh plugins snippets completions zmodules; do
      if [[ -e "${xdg_home}/${marker}" ]]; then
        xdg_present=1
        break
      fi
    done

    if (( legacy_present && xdg_present )); then
      if [[ $requested_bin == "${xdg_home}/bin" || $requested_bin == "${xdg_home}/bin/"* ]] ||
        [[ -z $requested_bin && -e "${xdg_home}/bin/zi.zsh" && ! -e "${legacy_home}/bin/zi.zsh" ]]; then
        ZI[HOME_DIR]="$xdg_home"
        ZI[HOME_LAYOUT]=ambiguous-xdg
      else
        ZI[HOME_DIR]="$legacy_home"
        ZI[HOME_LAYOUT]=ambiguous-legacy
      fi
    elif (( legacy_present )); then
      ZI[HOME_DIR]="$legacy_home"
      ZI[HOME_LAYOUT]=legacy
    else
      ZI[HOME_DIR]="$xdg_home"
      ZI[HOME_LAYOUT]=xdg
    fi
  elif [[ -z ${ZI[HOME_LAYOUT]} ]]; then
    ZI[HOME_LAYOUT]=explicit
  fi

  [[ -n ${ZI[BIN_DIR]} ]] || ZI[BIN_DIR]="${ZI[HOME_DIR]}/bin"
}

# Retained for compatibility: user configuration and third-party plugins read
# this value directly, so it must be defined rather than merely defaulted
# inside zi.zsh.
: "${ZI[MUTE_WARNINGS]:=0}"

# NOTE ON DEFAULTS
# Every other ZI[...] key is owned by zi.zsh. Do not duplicate defaults here;
# set a value in .zshrc before this file is sourced if you want to override it.
# The full set zi.zsh honours includes:
#
#   Paths        CACHE_DIR CONFIG_DIR COMPLETIONS_DIR PLUGINS_DIR SNIPPETS_DIR
#                SERVICES_DIR THEMES_DIR ZMODULES_DIR MAN_DIR LOG_DIR MAIL_DIR
#                CDPATH_DIR ZCOMPDUMP_PATH ZPFX
#   Behaviour    OPTIMIZE_OUT_DISK_ACCESSES COMPINIT_OPTS INTERNAL_ALIASES
#                PKG_OWNER
#
# Reference: https://wiki.zshell.dev/docs/guides/customization#customizing-paths

# Loader behaviour toggles.
#
# ZI[LOADER_HISTORY]  1 (default) applies the history defaults below. Set to 0
#                     before sourcing to leave HISTFILE, SAVEHIST, and HISTSIZE
#                     entirely to your own configuration.
: "${ZI[LOADER_HISTORY]:=1}"

# History defaults. These are a convenience for the installer's minimal .zshrc
# and are unrelated to loading Zi; ZI[LOADER_HISTORY]=0 disables them.
if [[ ${ZI[LOADER_HISTORY]} == 1 ]]; then
  : "${HISTFILE:=${XDG_STATE_HOME:-$HOME/.local/state}/zsh/history}"
  [[ -e "$HISTFILE" ]] || { command mkdir -p "${HISTFILE:h}" && command touch "$HISTFILE"; }
  [[ -w "$HISTFILE" ]] && typeset -gx SAVEHIST=440000 HISTSIZE=441000
fi

# ── Bootstrap Helpers ─────────────────────────────────────────────────────────

# Report a loader failure on stderr.
_zi_err() {
  builtin emulate -L zsh
  builtin print -u2 -P "%F{160}▓▒░ Zi loader: %f%b$1"
  return 0
}

# Fetch content from a URL to stdout.
_zi_fetch() {
  builtin emulate -L zsh
  if (( $+commands[curl] )); then
    command curl -fsSL "$1"
  elif (( $+commands[wget] )); then
    command wget -qO- "$1"
  else
    _zi_err "neither curl nor wget is available; cannot download."
    return 255
  fi
}

# Reject a stream name that git would not accept as a branch, before it reaches
# `git clone --branch` and produces an unattributed git error.
_zi_check_stream() {
  builtin emulate -L zsh
  local stream="${ZI[STREAM]}"
  if [[ -z $stream ]]; then
    _zi_err "ZI[STREAM] is empty; set it to a branch or tag name."
    return 1
  fi
  if [[ $stream == -* || $stream == *[[:space:]]* ]]; then
    _zi_err "ZI[STREAM] is not a valid ref name: ${(qqq)stream}"
    return 1
  fi
  if (( $+commands[git] )) &&
    ! command git check-ref-format --allow-onelevel "$stream" 2>/dev/null; then
    _zi_err "ZI[STREAM] is not a valid ref name: ${(qqq)stream}"
    return 1
  fi
  return 0
}

# Clone the Zi repository if it is not already present.
_zi_setup() {
  builtin emulate -L zsh
  builtin autoload colors; colors
  local -a git_refs
  local tmp_dir show_process process_url
  integer clone_status=0

  [[ -f "${ZI[BIN_DIR]}/zi.zsh" ]] && return 0

  if (( ! $+commands[git] )); then
    _zi_err "git is required to install Zi but was not found in PATH."
    return 1
  fi
  _zi_check_stream || return 1

  # A private, unpredictable directory. The progress filter is downloaded and
  # then executed, so it must never live at a fixed, world-writable path where
  # another user could pre-place a file for us to run.
  tmp_dir="$(command mktemp -d "${TMPDIR:-/tmp}/zi-loader.XXXXXX" 2>/dev/null)" || {
    _zi_err "could not create a private temporary directory."
    return 1
  }
  show_process="${tmp_dir}/git-process-output.zsh"
  process_url="https://raw.githubusercontent.com/z-shell/zi/main/lib/zsh/git-process-output.zsh"

  # The filter is cosmetic. If it cannot be fetched, fall back to plain output
  # rather than failing the install.
  if _zi_fetch "$process_url" > "$show_process" && [[ -s $show_process ]]; then
    command chmod u+x "$show_process"
  else
    show_process=""
  fi

  (( $+commands[clear] )) && command clear
  builtin print -P "%F{33}▓▒░ %F{160}Installing interactive & feature-rich plugin manager (%F{33}z-shell/zi%F{160})%f%b…\n"

  if command mkdir -p "${ZI[BIN_DIR]}"; then
    # --filter=blob:none keeps the clone small without making it shallow.
    # zi.zsh derives ZI[VERSION] from `git describe --tags`, which a --depth=1
    # clone would degrade to a bare short SHA.
    command git clone --verbose --progress \
      --filter=blob:none --single-branch \
      --branch "${ZI[STREAM]}" "${ZI[REPOSITORY]}" "${ZI[BIN_DIR]}" \
      |& { [[ -n $show_process ]] && command "$show_process" || command cat; }
    clone_status=${pipestatus[1]}
  else
    _zi_err "could not create ${(qqq)ZI[BIN_DIR]}"
    clone_status=1
  fi

  command rm -rf -- "$tmp_dir"

  if (( clone_status != 0 )) || [[ ! -f "${ZI[BIN_DIR]}/zi.zsh" ]]; then
    builtin print -P "%F{160}▓▒░  The clone has failed…%f%b"
    builtin print -P "%F{160}▓▒░ %F{33} Please report the issue: %F{226}https://github.com/z-shell/zi/issues/new%f%b"
    return 1
  fi

  # Scope the permission fix to the clone. ZI[HOME_DIR] also holds plugins,
  # snippets, and other user data that this loader does not own.
  command chmod -R go-w "${ZI[BIN_DIR]}"
  git_refs=("${(f@)$(builtin cd -q "${ZI[BIN_DIR]}" && command git log --color --graph --abbrev-commit \
    --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' | command head -5)}")
  builtin print
  builtin print -P "%F{33}▓▒░ %F{34}Successfully installed %F{160}(%F{33}z-shell/zi%F{160})%f%b\n"
  builtin print -rl -- "${git_refs[@]}"
  return 0
}

# Source zi.zsh, bootstrapping first if needed.
#
# zi.zsh's top level makes intentional global changes: it sets AUTO_CD when
# ZI[CDPATH_DIR] exists and marks path, manpath, cdpath, mailpath, fpath, and
# logpath as exported and unique. Wrapping the source in `emulate -L zsh` would
# localize those to this function and silently discard them, so instead only
# the options that would corrupt zi.zsh's own parsing are neutralized, then
# restored to the caller's values.
_zi_source() {
  local -A caller_opts
  local opt
  local -a guard=(
    sh_word_split ksh_arrays ksh_glob glob_subst rc_expand_param
    err_exit err_return no_unset warn_create_global
  )
  integer src_status

  if [[ ! -f "${ZI[BIN_DIR]}/zi.zsh" ]]; then
    _zi_setup || return 1
    # Guard: if setup reported success but zi.zsh is still missing, do not recurse.
    if [[ ! -f "${ZI[BIN_DIR]}/zi.zsh" ]]; then
      _zi_err "setup reported success but ${(qqq)ZI[BIN_DIR]}/zi.zsh is missing."
      return 1
    fi
  fi

  for opt in "${guard[@]}"; do
    caller_opts[$opt]="${options[$opt]}"
  done
  builtin setopt no_sh_word_split no_ksh_arrays no_ksh_glob no_glob_subst \
    no_rc_expand_param no_err_exit no_err_return unset no_warn_create_global

  builtin source "${ZI[BIN_DIR]}/zi.zsh"
  src_status=$?

  for opt in "${guard[@]}"; do
    options[$opt]="${caller_opts[$opt]}"
  done

  (( src_status == 0 )) || _zi_err "sourcing zi.zsh failed with status ${src_status}."
  return "$src_status"
}

# Load the zpmod module if it has been built.
_zi_pmod() {
  builtin emulate -L zsh
  local module_dir="${ZI[ZMODULES_DIR]:-${ZI[HOME_DIR]}/zmodules}/zpmod/Src"
  [[ -f "${module_dir}/zi/zpmod.so" ]] || return 0

  typeset -gU module_path
  module_path+=( "$module_dir" )
  if ! zmodload zi/zpmod 2>/dev/null; then
    [[ ${ZI[MUTE_WARNINGS]} == 1 ]] ||
      _zi_err "zpmod.so is present but zmodload zi/zpmod failed; rebuild it with \`zi module build\`."
    return 1
  fi
  return 0
}

# Register the Zi completion if the completion system is already active.
_zi_comps() {
  builtin emulate -L zsh
  (( ${+_comps} )) || return 0
  (( ${+_comps[zi]} )) || _comps[zi]=_zi
  return 0
}

# ── Entry Point ───────────────────────────────────────────────────────────────

zzinit() {
  integer status_source status_comps status_pmod

  # Sourcing Zi is the only hard prerequisite. Completion registration and the
  # optional module are independent: neither should be skipped because the
  # other reported a problem.
  _zi_source
  status_source=$?
  if (( status_source != 0 )); then
    _zi_err "Zi was not loaded. Fix the problem above, then run \`zzinit\` again."
    return "$status_source"
  fi

  _zi_comps
  status_comps=$?
  _zi_pmod
  status_pmod=$?

  # Helpers are only removed on success so a failed run stays retryable.
  unset -f _zi_err _zi_fetch _zi_check_stream _zi_setup _zi_source _zi_comps _zi_pmod zzinit 2>/dev/null

  (( status_comps == 0 && status_pmod == 0 ))
}
