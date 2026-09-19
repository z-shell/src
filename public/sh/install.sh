#!/usr/bin/env sh
# -*- mode: sh; sh-indentation: 2; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: ft=sh sw=2 ts=2 et

set -eu

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/zi-install.XXXXXX")" || exit 1
trap 'rm -rf "${WORKDIR:?}"' EXIT INT TERM
ZOPT=""
AOPT=""
BOPT="main"
while getopts ":i:a:b:" opt; do
  case ${opt} in
  i)
    ZOPT="${ZOPT}${OPTARG}"
    ;;
  a)
    AOPT="${AOPT}${OPTARG}"
    ;;
  b)
    BOPT="${OPTARG}"
    ;;
  \?)
    echo "Invalid option: ${OPTARG}" 1>&2
    exit 1
    ;;
  :)
    echo "Invalid option: ${OPTARG} requires an argument" 1>&2
    exit 1
    ;;
  *)
    echo "Invalid option: ${OPTARG}" 1>&2
    exit 1
    ;;
  esac
done
shift $((OPTIND - 1))

# Validate BOPT to prevent sed delimiter injection when building init.zsh.
# | is the sed delimiter used in the substitution; \ and & are special in
# sed replacement expressions. The *[\\]* pattern matches a single backslash.
case "${BOPT}" in
# [\\] is a bracket expression for a literal backslash.
*'|'* | *[\\]* | *'&'*)
  printf '%s\n' "-- ERROR -- Invalid -b value: branch name must not contain '|', '\\', or '&'." >&2
  exit 1
  ;;
esac

SCRIPT_DIR=""
LOCAL_INIT_ZSH=""
LOCAL_INSTALL_ZPMOD=""
case "$0" in
*/?*)
  SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
  ;;
*) ;;
esac

if [ -n "${SCRIPT_DIR}" ]; then
  if [ -f "${SCRIPT_DIR}/../zsh/init.zsh" ]; then
    LOCAL_INIT_ZSH="${SCRIPT_DIR}/../zsh/init.zsh"
  fi
  if [ -f "${SCRIPT_DIR}/install_zpmod.sh" ]; then
    LOCAL_INSTALL_ZPMOD="${SCRIPT_DIR}/install_zpmod.sh"
  fi
fi

fetch_to_file() {
  _dest="$1"
  shift
  _has_fetcher=0

  for _src; do
    [ -n "${_src}" ] || continue
    case "${_src}" in
    http://* | https://*)
      if command -v curl >/dev/null 2>&1; then
        _has_fetcher=1
        if command curl -fsSL "${_src}" -o "${_dest}" 2>/dev/null; then
          return 0
        fi
      elif command -v wget >/dev/null 2>&1; then
        _has_fetcher=1
        if command wget -qO "${_dest}" "${_src}" 2>/dev/null; then
          return 0
        fi
      fi
      ;;
    *)
      if [ -r "${_src}" ]; then
        command cp "${_src}" "${_dest}"
        return 0
      fi
      ;;
    esac
  done

  if [ "${_has_fetcher}" -eq 0 ]; then
    printf '%s\n' "-- ERROR -- curl or wget is required to download installer assets" >&2
  fi
  return 1
}

is_absolute_path() {
  case "${1-}" in
  /*) return 0 ;;
  *) return 1 ;;
  esac
}

zi_home_has_installation() {
  [ -f "$1/bin/zi.zsh" ] ||
    [ -d "$1/plugins" ] ||
    [ -d "$1/snippets" ] ||
    [ -d "$1/completions" ] ||
    [ -d "$1/zmodules" ]
}

if [ "${AOPT}" = loader ]; then
  if is_absolute_path "${XDG_CONFIG_HOME-}"; then
    ZI_CONFIG_DIR="${XDG_CONFIG_HOME}/zi"
  else
    ZI_CONFIG_DIR="${HOME}/.config/zi"
  fi
  loader_tmp="${WORKDIR}/init.zsh.tmp"
  command mkdir -p "${ZI_CONFIG_DIR}"
  set +e
  fetch_to_file "${ZI_CONFIG_DIR}/init.zsh" \
    "${LOCAL_INIT_ZSH}" \
    "https://raw.githubusercontent.com/z-shell/src/main/public/zsh/init.zsh" \
    "https://raw.githubusercontent.com/z-shell/src/main/lib/zsh/init.zsh"
  fetch_status=$?
  set -e
  if [ "${fetch_status}" -ne 0 ]; then
    printf '%s\n' "-- ERROR -- failed to retrieve init.zsh" >&2
    exit 1
  fi
  # shellcheck disable=SC2016
  command sed 's|: "${ZI\[STREAM\]:=main}"|: "${ZI[STREAM]:='"${BOPT}"'}"|' "${ZI_CONFIG_DIR}/init.zsh" >"${loader_tmp}" &&
    command mv "${loader_tmp}" "${ZI_CONFIG_DIR}/init.zsh"
  command chmod go-w "${ZI_CONFIG_DIR}" && command chmod a+x "${ZI_CONFIG_DIR}/init.zsh"
fi

if [ -z "${ZI_HOME-}" ]; then
  if is_absolute_path "${XDG_DATA_HOME-}"; then
    _zi_data_base="${XDG_DATA_HOME}"
  else
    _zi_data_base="${HOME}/.local/share"
  fi
  _zi_legacy_home="${HOME}/.zi"
  _zi_xdg_home="${_zi_data_base}/zi"
  _zi_legacy_present=0
  _zi_xdg_present=0
  zi_home_has_installation "${_zi_legacy_home}" && _zi_legacy_present=1
  zi_home_has_installation "${_zi_xdg_home}" && _zi_xdg_present=1

  if [ "${_zi_legacy_present}" -eq 1 ] && [ "${_zi_xdg_present}" -eq 1 ]; then
    if [ -f "${_zi_xdg_home}/bin/zi.zsh" ] && [ ! -f "${_zi_legacy_home}/bin/zi.zsh" ]; then
      ZI_HOME="${_zi_xdg_home}"
    else
      ZI_HOME="${_zi_legacy_home}"
      printf '%s\n' "Zi installer: both legacy and XDG homes were detected; retaining ${ZI_HOME}. Set ZI_HOME explicitly to select another root. No data was moved." >&2
    fi
  elif [ "${_zi_legacy_present}" -eq 1 ]; then
    ZI_HOME="${_zi_legacy_home}"
  else
    ZI_HOME="${_zi_xdg_home}"
  fi
fi

if [ -z "${ZI_BIN_DIR_NAME-}" ]; then
  ZI_BIN_DIR_NAME="bin"
fi

if ! test -d "${ZI_HOME}"; then
  command mkdir -p "${ZI_HOME}"
  command chmod 700 "${ZI_HOME}"
fi

if ! command -v git >/dev/null 2>&1; then
  printf '%s\n' "[1;31m▓▒░[0m Something went wrong: no [1;32mgit[0m available, cannot proceed."
  exit 1
fi

# -b is used as a fetch refspec and inside generated Zsh: accept only a
# well-formed branch name (no ':', no leading '-', no '..').
if ! command git check-ref-format --branch "${BOPT}" >/dev/null 2>&1; then
  printf '%s\n' "-- ERROR -- Invalid -b value: '${BOPT}' is not a valid branch name." >&2
  exit 1
fi

# Get the download-progress bar tool
command mkdir -p /tmp/zi
cd /tmp/zi || exit 1
set +e
fetch_to_file /tmp/zi/git-process-output.zsh \
  "" \
  "https://raw.githubusercontent.com/z-shell/zi/main/public/zsh/git-process-output.zsh" \
  "https://raw.githubusercontent.com/z-shell/zi/main/lib/zsh/git-process-output.zsh"
fetch_status=$?
set -e
if [ "${fetch_status}" -ne 0 ]; then
  printf '%s\n' "-- ERROR -- failed to retrieve git-process-output.zsh" >&2
  exit 1
fi
command chmod a+x /tmp/zi/git-process-output.zsh

if test -d "${ZI_HOME}/${ZI_BIN_DIR_NAME}/.git"; then
  _zi_valid=0
  if test -f "${ZI_HOME}/${ZI_BIN_DIR_NAME}/zi.zsh"; then
    # Canonical zi remote URLs (HTTPS and SSH, with and without .git suffix)
    case "$(command git -C "${ZI_HOME}/${ZI_BIN_DIR_NAME}" remote get-url origin 2>/dev/null || true)" in
    https://github.com/z-shell/zi | https://github.com/z-shell/zi.git | \
      git@github.com:z-shell/zi | git@github.com:z-shell/zi.git)
      _zi_valid=1
      ;;
    esac
  fi
  if [ "${_zi_valid}" -ne 1 ]; then
    printf '%s\n' "[1;31m▓▒░[0m ${ZI_HOME}/${ZI_BIN_DIR_NAME} contains a .git directory but does not appear to be a zi repository." >&2
    printf '%s\n' "[1;31m▓▒░[0m Expected zi.zsh and a z-shell/zi remote origin. Unset ZI_HOME/ZI_BIN_DIR_NAME or remove the directory to install fresh." >&2
    exit 1
  fi
  cd "${ZI_HOME}/${ZI_BIN_DIR_NAME}" || exit 1
  printf '%s\n' "[1;34m▓▒░[0m Updating [1;36m(z-shell/zi)[1;33m plugin manager[0m at [1;35m${ZI_HOME}/${ZI_BIN_DIR_NAME}[0m"
  # Match `zi self-update`: fetch the requested branch and fast-forward only.
  # Local state is never discarded; refuse loudly when it cannot be advanced.
  if ! command git fetch -q origin "refs/heads/${BOPT}"; then
    printf '%s\n' "-- ERROR -- failed to fetch origin ${BOPT} into ${ZI_HOME}/${ZI_BIN_DIR_NAME}" >&2
    exit 1
  fi
  if ! command git merge -q --ff-only FETCH_HEAD; then
    printf '%s\n' "-- ERROR -- ${ZI_HOME}/${ZI_BIN_DIR_NAME} cannot be fast-forwarded to origin/${BOPT}; local state was left untouched:" >&2
    command git status --short --branch 2>/dev/null | head -20 >&2
    printf '%s\n' "-- ERROR -- resolve the checkout state shown above so HEAD can fast-forward to origin/${BOPT} (move local commits to another branch, or drop changes you do not need), then rerun the installer." >&2
    exit 1
  fi
else
  cd "${ZI_HOME}" || exit 1
  printf '%s\n' "[1;34m▓▒░[0m Installing [1;36m(z-shell/zi)[1;33m plugin manager[0m at [1;35m${ZI_HOME}/${ZI_BIN_DIR_NAME}[0m"
  { git clone --progress --depth=1 --branch "${BOPT}" https://github.com/z-shell/zi.git "${ZI_BIN_DIR_NAME}" \
    2>&1 | { /tmp/zi/git-process-output.zsh || cat; }; } 2>/dev/null
  if [ -d "${ZI_HOME}/${ZI_BIN_DIR_NAME}" ] && [ -f "${ZI_HOME}/${ZI_BIN_DIR_NAME}/zi.zsh" ]; then
    printf '%s\n' "[1;34m▓▒░[0m Successfully installed at [1;32m${ZI_HOME}/${ZI_BIN_DIR_NAME}[0m".
  else
    printf '%s\n' "[1;31m▓▒░[0m Something went wrong, couldn't install ZI at [1;33m${ZI_HOME}/${ZI_BIN_DIR_NAME}[0m"
    exit 1
  fi
fi

#
# Modify .zshrc
#

MAIN_PROFILE() {
  THE_ZDOTDIR="${ZDOTDIR:-${HOME}}"
  ZSHRC_INTEGRATED=0
  # Detect an existing Zi integration by a real source line. A comment that
  # merely mentions the file name must not suppress the integration.
  if grep -E '^[[:space:]]*(source|\.)[[:space:]]+[^#]*(zi|init|zinit)\.zsh(["'"'"'[:space:]]|$)' "${THE_ZDOTDIR}/.zshrc" >/dev/null 2>&1; then
    printf '%s\n' "[34m▓▒░[34m Seems that .zshrc already sources Zi - the integration block will not be added."
    ZSHRC_INTEGRATED=1
  fi
  # The .zshrc text refers to the home through $HOME; the installer itself
  # keeps using the real path.
  # shellcheck disable=SC2016
  case "${ZI_HOME}" in
  "${HOME}") ZI_HOME_TEXT='$HOME' ;;
  "${HOME}"/*) ZI_HOME_TEXT="\$HOME${ZI_HOME#"${HOME}"}" ;;
  *) ZI_HOME_TEXT="${ZI_HOME}" ;;
  esac
  if [ "${ZOPT}" != skip ] && [ "${ZSHRC_INTEGRATED}" -eq 0 ] && [ "${AOPT}" != loader ]; then
    printf '%s\n' "[34m▓▒░[0m Updating ${THE_ZDOTDIR}/.zshrc"
    command cat <<-EOF >>"${THE_ZDOTDIR}/.zshrc"
if [[ ! -f ${ZI_HOME_TEXT}/${ZI_BIN_DIR_NAME}/zi.zsh ]]; then
  print -P "%F{33}▓▒░ %F{160}Installing (%F{33}z-shell/zi%F{160})…%f"
  command mkdir -p "${ZI_HOME_TEXT}" && command chmod go-rwX "${ZI_HOME_TEXT}"
  command git clone -q --filter=blob:none --single-branch --branch "${BOPT}" https://github.com/z-shell/zi "${ZI_HOME_TEXT}/${ZI_BIN_DIR_NAME}" && \\
    print -P "%F{33}▓▒░ %F{34}Installation successful.%f%b" || \\
    print -P "%F{160}▓▒░ The clone has failed.%f%b"
fi
source "${ZI_HOME_TEXT}/${ZI_BIN_DIR_NAME}/zi.zsh"
autoload -Uz _zi
(( \${+_comps} )) && _comps[zi]=_zi
# examples here -> https://wiki.zshell.dev/ecosystem/category/-annexes
zicompinit # <- https://wiki.zshell.dev/docs/guides/commands
EOF
    printf '%s\n' "[34m▓▒░[0m[1;36m Minimal configuration[0m"
  fi
  if [ "${AOPT}" = loader ] && [ "${ZOPT}" != skip ] && [ "${ZSHRC_INTEGRATED}" -eq 0 ]; then
    command cat <<-EOF >>"${THE_ZDOTDIR}/.zshrc"
if [[ -n \${XDG_CONFIG_HOME:-} && \${XDG_CONFIG_HOME} == /* ]]; then
  ZI_LOADER_CONFIG_HOME="\${XDG_CONFIG_HOME}/zi"
else
  ZI_LOADER_CONFIG_HOME="\${HOME}/.config/zi"
fi
if [[ -r "\${ZI_LOADER_CONFIG_HOME}/init.zsh" ]]; then
  source "\${ZI_LOADER_CONFIG_HOME}/init.zsh" && zzinit
fi
unset ZI_LOADER_CONFIG_HOME
EOF
    printf '%s\n' "[34m▓▒░[0m[1;36m Loader added[0m"
  fi
}

ANNEX_PROFILE() {
  if [ "${AOPT}" != annex ] && [ "${AOPT}" != zunit ]; then
    printf '%s\n' "[34m▓▒░[0m[1;36m Skipped all annexes[0m"
    return 0
  fi
  if [ "${ZOPT}" = skip ]; then
    printf '%s\n' "[34m▓▒░[0m[1;36m .zshrc changes were skipped (-i skip); annexes were not configured[0m"
    return 0
  fi
  # Rerunning the installer must not append the block a second time.
  if grep -E '^[^#]*z-shell/z-a-meta-plugins([[:space:]]|$)' "${THE_ZDOTDIR}/.zshrc" >/dev/null 2>&1; then
    printf '%s\n' "[34m▓▒░[0m[1;36m .zshrc already loads z-shell/z-a-meta-plugins - annex block not added again[0m"
    return 0
  fi
  file="${WORKDIR}/temp-zsh-config"
  if [ "${AOPT}" = annex ]; then
    command cat <<-EOF >"${file}"
zi light-mode for \\
  z-shell/z-a-meta-plugins \\
  @annexes # <- https://wiki.zshell.dev/ecosystem/category/-annexes
# examples here -> https://wiki.zshell.dev/community/gallery/collection
zicompinit # <- https://wiki.zshell.dev/docs/guides/commands
EOF
    printf '%s\n' "[34m▓▒░[0m[1;36m Installing annexes[0m"
  else
    command cat <<-EOF >"${file}"
zi light-mode for \\
  z-shell/z-a-meta-plugins \\
  @annexes @zunit
EOF
    printf '%s\n' "[34m▓▒░[0m[1;36m Installing annexes + zunit[0m"
  fi
  command cat "${file}" >>"${THE_ZDOTDIR}/.zshrc"
  ANNEX_BURST "${file}"
}

ANNEX_BURST() {
  # Install the annexes now without an interactive shell and with -f, so no
  # user startup file (not even .zshenv) runs: source only zi.zsh and the
  # fragment just written. A failure here must not abort an install whose
  # .zshrc changes are already in place.
  if zsh -f -c 'builtin source "$1" && builtin source "$2" && @zi-scheduler burst' zsh \
    "${ZI_HOME}/${ZI_BIN_DIR_NAME}/zi.zsh" "$1"; then
    return 0
  fi
  printf '%s\n' "[34m▓▒░[0m[1;33m Annexes could not be installed now; they will be installed on the next shell start.[0m" >&2
  return 0
}

ZPMOD_PROFILE() {
  _zpmod_sh=""
  if [ -n "${LOCAL_INSTALL_ZPMOD}" ]; then
    _zpmod_sh="${LOCAL_INSTALL_ZPMOD}"
  else
    _zpmod_sh="${WORKDIR}/install_zpmod.sh"
    set +e
    fetch_to_file "${_zpmod_sh}" \
      "" \
      "https://raw.githubusercontent.com/z-shell/src/main/public/sh/install_zpmod.sh" \
      "https://raw.githubusercontent.com/z-shell/src/main/lib/sh/install_zpmod.sh"
    fetch_status=$?
    set -e
    if [ "${fetch_status}" -ne 0 ]; then
      printf '%s\n' "-- ERROR -- failed to download install_zpmod.sh" >&2
      exit 1
    fi
    command chmod a+x "${_zpmod_sh}"
  fi

  if [ "$#" -gt 0 ]; then
    exec sh "${_zpmod_sh}" "$@"
  fi
  exec sh "${_zpmod_sh}"
}

CLOSE_PROFILE() {
  git_refs="$(
    command cd "${ZI_HOME}/${ZI_BIN_DIR_NAME}" || true
    command git log --color --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit | head -5
  )"
  printf '%s\n' "[34m▓▒░[0m[38;5;226m Latest changes:[0m"
  printf '%s\n' "${git_refs}"
}

MAIN() {
  if [ "${AOPT}" = zpmod ]; then
    if [ "$#" -gt 0 ]; then
      ZPMOD_PROFILE "$@"
    else
      ZPMOD_PROFILE
    fi
  else
    MAIN_PROFILE
    ANNEX_PROFILE
    CLOSE_PROFILE
  fi
  command cat <<-EOF
[34m▓▒░[0m[1;36m ■■■■■■■■■■■■■■■■■ Successfully installed ❮ ZI ❯ ■■■■■■■■■[0m
[34m▓▒░[0m[38;5;226m Wiki:         https://wiki.zshell.dev[0m
[34m▓▒░[0m[38;5;226m Issues:       https://github.com/z-shell/zi/issues[0m
[34m▓▒░[0m[38;5;226m Discussions:  https://discussions.zshell.dev[0m
[34m▓▒░[0m[1;36m ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■[0m
EOF
  exit 0
}

if [ "$#" -gt 0 ]; then
  MAIN "$@"
else
  MAIN
fi
