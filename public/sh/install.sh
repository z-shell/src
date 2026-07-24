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

# Validate BOPT to prevent sed delimiter injection
case "${BOPT}" in
  *'|'* | *'\'* | *'&'*)
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

if [ "${AOPT}" = loader ]; then
  ZI_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/zi"
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
  command sed 's|: ${ZI\[STREAM\]:="main"}|: ${ZI[STREAM]:="'"${BOPT}"'"}|' "${ZI_CONFIG_DIR}/init.zsh" >"${loader_tmp}" &&
    command mv "${loader_tmp}" "${ZI_CONFIG_DIR}/init.zsh"
  command chmod go-w "${ZI_CONFIG_DIR}" && command chmod a+x "${ZI_CONFIG_DIR}/init.zsh"
fi

if [ -z "${ZI_HOME-}" ]; then
  ZI_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zi"
fi

if [ -z "${ZI_BIN_DIR_NAME-}" ]; then
  ZI_BIN_DIR_NAME="bin"
fi

if ! test -d "${ZI_HOME}"; then
  command mkdir -p "${ZI_HOME}"
  command chmod go-w "${ZI_HOME}"
fi

if ! command -v git >/dev/null 2>&1; then
  printf '%s\n' "[1;31m▓▒░[0m Something went wrong: no [1;32mgit[0m available, cannot proceed."
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
    _zi_remote="$(command git -C "${ZI_HOME}/${ZI_BIN_DIR_NAME}" remote get-url origin 2>/dev/null || true)"
    if printf '%s\n' "${_zi_remote}" | grep -q 'z-shell/zi'; then
      _zi_valid=1
    fi
  fi
  if [ "${_zi_valid}" -ne 1 ]; then
    printf '%s\n' "[1;31m▓▒░[0m ${ZI_HOME}/${ZI_BIN_DIR_NAME} contains a .git directory but does not appear to be a zi repository." >&2
    printf '%s\n' "[1;31m▓▒░[0m Expected zi.zsh and a z-shell/zi remote origin. Unset ZI_HOME/ZI_BIN_DIR_NAME or remove the directory to install fresh." >&2
    exit 1
  fi
  cd "${ZI_HOME}/${ZI_BIN_DIR_NAME}" || exit 1
  printf '%s\n' "[1;34m▓▒░[0m Updating [1;36m(z-shell/zi)[1;33m plugin manager[0m at [1;35m${ZI_HOME}/${ZI_BIN_DIR_NAME}[0m"
  command git clean -d -f -f
  command git reset --hard HEAD
  command git pull -q origin "${BOPT}"
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
  if grep -E '(zi|init|zinit)\.zsh' "${THE_ZDOTDIR}/.zshrc" >/dev/null 2>&1; then
    printf '%s\n' "[34m▓▒░[34m Seems that .zshrc already has content or setup skipped - no changes will be made."
    ZOPT='skip'
  fi
  if [ "${ZOPT}" != skip ] && [ "${AOPT}" != loader ]; then
    printf '%s\n' "[34m▓▒░[0m Updating ${THE_ZDOTDIR}/.zshrc"
    ZI_HOME="$(echo "${ZI_HOME}" | sed "s|${HOME}|\$HOME|")"
    command cat <<-EOF >>"${THE_ZDOTDIR}/.zshrc"
if [[ ! -f ${ZI_HOME}/${ZI_BIN_DIR_NAME}/zi.zsh ]]; then
  print -P "%F{33}▓▒░ %F{160}Installing (%F{33}z-shell/zi%F{160})…%f"
  command mkdir -p "${ZI_HOME}" && command chmod go-rwX "${ZI_HOME}"
  command git clone -q --depth=1 --branch "${BOPT}" https://github.com/z-shell/zi "${ZI_HOME}/${ZI_BIN_DIR_NAME}" && \\
    print -P "%F{33}▓▒░ %F{34}Installation successful.%f%b" || \\
    print -P "%F{160}▓▒░ The clone has failed.%f%b"
fi
source "${ZI_HOME}/${ZI_BIN_DIR_NAME}/zi.zsh"
autoload -Uz _zi
(( \${+_comps} )) && _comps[zi]=_zi
# examples here -> https://wiki.zshell.dev/ecosystem/category/-annexes
zicompinit # <- https://wiki.zshell.dev/docs/guides/commands
EOF
    printf '%s\n' "[34m▓▒░[0m[1;36m Minimal configuration[0m"
  fi
  if [ "${AOPT}" = loader ] && [ "${ZOPT}" != skip ]; then
    command cat <<-EOF >>"${THE_ZDOTDIR}/.zshrc"
if [[ -r "\${XDG_CONFIG_HOME:-\${HOME}/.config}/zi/init.zsh" ]]; then
  source "\${XDG_CONFIG_HOME:-\${HOME}/.config}/zi/init.zsh" && zzinit
fi
EOF
    printf '%s\n' "[34m▓▒░[0m[1;36m Loader added[0m"
  fi
}

ANNEX_PROFILE() {
  if [ "${AOPT}" = annex ]; then
    file="${WORKDIR}/temp-zsh-config"
    command cat <<-EOF >>"${file}"
zi light-mode for \\
  z-shell/z-a-meta-plugins \\
  @annexes # <- https://wiki.zshell.dev/ecosystem/category/-annexes
# examples here -> https://wiki.zshell.dev/community/gallery/collection
zicompinit # <- https://wiki.zshell.dev/docs/guides/commands
EOF
    printf '%s\n' "[34m▓▒░[0m[1;36m Installing annexes[0m"
    command cat "${file}" >>"${THE_ZDOTDIR}/.zshrc"
    zsh -ic "@zi-scheduler burst"
  elif [ "${AOPT}" = zunit ]; then
    file2="${WORKDIR}/temp-zunit-config"
    command cat <<-EOF >>"${file2}"
zi light-mode for \\
  z-shell/z-a-meta-plugins \\
  @annexes @zunit
EOF
    printf '%s\n' "[34m▓▒░[0m[1;36m Installing annexes + zunit[0m"
    command cat "${file2}" >>"${THE_ZDOTDIR}/.zshrc"
    zsh -ic "@zi-scheduler burst"
  else
    printf '%s\n' "[34m▓▒░[0m[1;36m Skipped all annexes[0m"
  fi
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
