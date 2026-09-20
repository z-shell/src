#!/usr/bin/env sh
# -*- mode: sh; sh-indentation: 2; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: ft=sh sw=2 ts=2 et

set -eu

ZOPT=""
AOPT=loader
BOPT=main
BOPT_EXPLICIT=0
while getopts ":i:a:b:" opt; do
  case ${opt} in
  i) ZOPT="${OPTARG}" ;;
  a) AOPT="${OPTARG}" ;;
  b)
    BOPT="${OPTARG}"
    BOPT_EXPLICIT=1
    ;;
  \?)
    printf '%s\n' "Invalid option: ${OPTARG}" >&2
    exit 1
    ;;
  :)
    printf '%s\n' "Invalid option: ${OPTARG} requires an argument" >&2
    exit 1
    ;;
  *)
    printf '%s\n' "Invalid option: ${OPTARG}" >&2
    exit 1
    ;;
  esac
done
shift $((OPTIND - 1))

case "${ZOPT}" in "" | skip) ;; *)
  printf '%s\n' "-- ERROR -- Unsupported -i profile: ${ZOPT}" >&2
  exit 1
  ;;
esac
case "${AOPT}" in
loader | annex | zunit | zpmod) ;;
direct)
  printf '%s\n' 'Zi installer: the direct zi.zsh profile is deprecated; using the guided loader profile.' >&2
  AOPT=loader
  ;;
*)
  printf '%s\n' "-- ERROR -- Unsupported -a profile: ${AOPT}" >&2
  exit 1
  ;;
esac
case "${ZDOTDIR-}" in "" | /*) ;; *)
  printf '%s\n' "-- ERROR -- ZDOTDIR must be an absolute path when set: ${ZDOTDIR}" >&2
  exit 1
  ;;
esac
case "${ZI_HOME-}" in "" | /*) ;; *)
  printf '%s\n' "-- ERROR -- ZI_HOME must be an absolute path when set: ${ZI_HOME}" >&2
  exit 1
  ;;
esac
ZI_SRC_REF="${ZI_SRC_REF:-main}"
case "${ZI_SRC_REF}" in
"" | -* | *..* | *[!A-Za-z0-9._/-]*)
  printf '%s\n' "-- ERROR -- Invalid ZI_SRC_REF: ${ZI_SRC_REF}" >&2
  exit 1
  ;;
esac
command git check-ref-format --branch "${ZI_SRC_REF}" >/dev/null 2>&1 || {
  printf '%s\n' "-- ERROR -- ZI_SRC_REF is not a valid Git ref: ${ZI_SRC_REF}" >&2
  exit 1
}
ZI_SRC_ASSET_ROOT="https://raw.githubusercontent.com/z-shell/src/${ZI_SRC_REF}/public"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/zi-install.XXXXXX")" || exit 1
trap 'rm -rf "${WORKDIR:?}"' EXIT INT TERM

SCRIPT_DIR=""
case "$0" in
*/?*) SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || SCRIPT_DIR="" ;;
*) ;;
esac

fetch_to_file() {
  _fetch_dest="$1"
  shift
  _fetch_has_tool=0
  for _fetch_source; do
    [ -n "${_fetch_source}" ] || continue
    case "${_fetch_source}" in
    http://* | https://*)
      if command -v curl >/dev/null 2>&1; then
        _fetch_has_tool=1
        command curl -fsSL "${_fetch_source}" -o "${_fetch_dest}" 2>/dev/null && return 0
      elif command -v wget >/dev/null 2>&1; then
        _fetch_has_tool=1
        command wget -qO "${_fetch_dest}" "${_fetch_source}" 2>/dev/null && return 0
      fi
      ;;
    *)
      if [ -r "${_fetch_source}" ]; then
        command cp "${_fetch_source}" "${_fetch_dest}" && return 0
      fi
      ;;
    esac
  done
  [ "${_fetch_has_tool}" -ne 0 ] || printf '%s\n' '-- ERROR -- curl or wget is required to download installer assets' >&2
  return 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf '%s\n' '-- ERROR -- sha256sum or shasum is required' >&2
    exit 1
  fi
}

verify_asset() {
  _verify_file="$1"
  _verify_name="$2"
  _verify_checksum="$3"
  _verify_expected="$(awk -v name="${_verify_name}" '$2 == name {print $1}' "${_verify_checksum}")"
  [ -n "${_verify_expected}" ] || {
    printf '%s\n' "-- ERROR -- checksum entry missing for ${_verify_name}" >&2
    exit 1
  }
  [ "$(sha256_file "${_verify_file}")" = "${_verify_expected}" ] || {
    printf '%s\n' "-- ERROR -- checksum verification failed for ${_verify_name}" >&2
    exit 1
  }
}

LOCAL_INIT=""
LOCAL_SETUP=""
LOCAL_PROFILES=""
LOCAL_CHECKSUM=""
LOCAL_ZPMOD=""
if [ -n "${SCRIPT_DIR}" ]; then
  [ ! -f "${SCRIPT_DIR}/../zsh/init.zsh" ] || LOCAL_INIT="${SCRIPT_DIR}/../zsh/init.zsh"
  [ ! -f "${SCRIPT_DIR}/setup.sh" ] || LOCAL_SETUP="${SCRIPT_DIR}/setup.sh"
  [ ! -f "${SCRIPT_DIR}/../setup/profiles.tsv" ] || LOCAL_PROFILES="${SCRIPT_DIR}/../setup/profiles.tsv"
  [ ! -f "${SCRIPT_DIR}/../checksum.txt" ] || LOCAL_CHECKSUM="${SCRIPT_DIR}/../checksum.txt"
  [ ! -f "${SCRIPT_DIR}/install_zpmod.sh" ] || LOCAL_ZPMOD="${SCRIPT_DIR}/install_zpmod.sh"
fi

CHECKSUM_ASSET="${LOCAL_CHECKSUM}"
if [ -z "${CHECKSUM_ASSET}" ]; then
  CHECKSUM_ASSET="${WORKDIR}/checksum.txt"
  fetch_to_file "${CHECKSUM_ASSET}" \
    "${ZI_SRC_ASSET_ROOT}/checksum.txt" || {
    printf '%s\n' '-- ERROR -- failed to retrieve checksum manifest' >&2
    exit 1
  }
fi

INIT_ASSET="${LOCAL_INIT}"
if [ -z "${INIT_ASSET}" ]; then
  INIT_ASSET="${WORKDIR}/init.zsh"
  fetch_to_file "${INIT_ASSET}" \
    "${ZI_SRC_ASSET_ROOT}/zsh/init.zsh" || {
    printf '%s\n' '-- ERROR -- failed to retrieve init.zsh' >&2
    exit 1
  }
fi

SETUP_ASSET="${LOCAL_SETUP}"
if [ -z "${SETUP_ASSET}" ]; then
  SETUP_ASSET="${WORKDIR}/setup.sh"
  fetch_to_file "${SETUP_ASSET}" \
    "${ZI_SRC_ASSET_ROOT}/sh/setup.sh" || {
    printf '%s\n' '-- ERROR -- failed to retrieve setup.sh' >&2
    exit 1
  }
fi

PROFILES_ASSET="${LOCAL_PROFILES}"
if [ -z "${PROFILES_ASSET}" ]; then
  PROFILES_ASSET="${WORKDIR}/profiles.tsv"
  fetch_to_file "${PROFILES_ASSET}" \
    "${ZI_SRC_ASSET_ROOT}/setup/profiles.tsv" || {
    printf '%s\n' '-- ERROR -- failed to retrieve setup profile table' >&2
    exit 1
  }
fi

verify_asset "${INIT_ASSET}" public/zsh/init.zsh "${CHECKSUM_ASSET}"
verify_asset "${SETUP_ASSET}" public/sh/setup.sh "${CHECKSUM_ASSET}"
verify_asset "${PROFILES_ASSET}" public/setup/profiles.tsv "${CHECKSUM_ASSET}"

PLAN_DIR="${WORKDIR}/plan"
if [ "${AOPT}" = zpmod ]; then PLAN_PROFILE=loader; else PLAN_PROFILE="${AOPT}"; fi

create_plan() (
  set -- plan \
    --plan "${PLAN_DIR}" \
    --profile "${PLAN_PROFILE}" \
    --init "${INIT_ASSET}" \
    --profiles "${PROFILES_ASSET}" \
    --checksum "${CHECKSUM_ASSET}"
  if [ "${BOPT_EXPLICIT}" -eq 1 ]; then set -- "$@" --ref "${BOPT}"; fi
  if [ -n "${ZI_HOME-}" ]; then set -- "$@" --zi-home "${ZI_HOME}"; fi
  if [ -n "${ZI_BIN_DIR_NAME-}" ]; then set -- "$@" --zi-bin-dir "${ZI_BIN_DIR_NAME}"; fi
  if [ "${ZOPT}" = skip ]; then set -- "$@" --skip-zshrc; fi
  sh "${SETUP_ASSET}" "$@"
)
create_plan

PLAN_ID="$(cat "${PLAN_DIR}/plan.id")"
sh "${SETUP_ASSET}" apply --plan "${PLAN_DIR}" --phase checkout --expect "${PLAN_ID}"
sh "${SETUP_ASSET}" apply --plan "${PLAN_DIR}" --phase files --expect "${PLAN_ID}"

CHECKOUT_PATH="$(sed -n 's/^checkout_path=//p' "${PLAN_DIR}/plan.meta")"
if [ "${AOPT}" = zpmod ]; then
  ZPMOD_ASSET="${LOCAL_ZPMOD}"
  if [ -z "${ZPMOD_ASSET}" ]; then
    ZPMOD_ASSET="${WORKDIR}/install_zpmod.sh"
    fetch_to_file "${ZPMOD_ASSET}" \
      "${ZI_SRC_ASSET_ROOT}/sh/install_zpmod.sh" || {
      printf '%s\n' '-- ERROR -- failed to retrieve install_zpmod.sh' >&2
      exit 1
    }
    verify_asset "${ZPMOD_ASSET}" public/sh/install_zpmod.sh "${CHECKSUM_ASSET}"
  fi
  if [ "$#" -gt 0 ]; then sh "${ZPMOD_ASSET}" "$@"; else sh "${ZPMOD_ASSET}"; fi
fi

printf '%s\n' "Successfully installed at ${CHECKOUT_PATH}"
if [ "${PLAN_PROFILE}" = annex ] || [ "${PLAN_PROFILE}" = zunit ]; then
  printf '%s\n' 'Zi installer: recipe installation is deferred to the first shell start.'
fi

if [ -d "${CHECKOUT_PATH}/.git" ]; then
  git_refs="$(command git -C "${CHECKOUT_PATH}" log --color --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit 2>/dev/null | head -5 || true)"
  if [ -n "${git_refs}" ]; then
    printf '%s\n' 'Latest changes:'
    printf '%s\n' "${git_refs}"
  fi
fi

command cat <<'EOF'
Successfully installed Zi.
Wiki:         https://wiki.zshell.dev
Issues:       https://github.com/z-shell/zi/issues
Discussions:  https://discussions.zshell.dev
EOF
