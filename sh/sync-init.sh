#!/usr/bin/env sh
# -*- mode: sh; sh-indentation: 2; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: ft=sh sw=2 ts=2 et
#
# sync-init.sh — verify and optionally sync local public/zsh/init.zsh with remote.
#
# Usage:
#   sh public/sh/sync-init.sh [OPTIONS]
#
# Options:
#   --write                  Replace local file with remote copy (requires valid checksum)
#   --local PATH             Local file to compare (default: public/zsh/init.zsh)
#   --remote URL|PATH        Remote URL or local path (default: GitHub raw main)
#   --checksum-url URL|PATH  Checksum.txt URL or path (default: GitHub raw main)
#   --no-checksum            Skip checksum validation of remote content
#   --help                   Print this help and exit
#
# Exit codes:
#   0  Files match (or --write sync succeeded)
#   1  Files differ, fetch error, or checksum mismatch
#   2  Usage error

set -eu

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/zi-sync.XXXXXX")" || exit 1
trap 'rm -rf "${WORKDIR:?}"' EXIT INT TERM

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DEFAULT_LOCAL="${REPO_ROOT}/public/zsh/init.zsh"
DEFAULT_REMOTE="https://raw.githubusercontent.com/z-shell/src/main/public/zsh/init.zsh"
DEFAULT_CHECKSUM_URL="https://raw.githubusercontent.com/z-shell/src/main/public/checksum.txt"
CHECKSUM_KEY="public/zsh/init.zsh"

OPT_LOCAL="${DEFAULT_LOCAL}"
OPT_REMOTE="${DEFAULT_REMOTE}"
OPT_CHECKSUM_URL="${DEFAULT_CHECKSUM_URL}"
OPT_WRITE=0
OPT_NO_CHECKSUM=0

# ── Helpers ───────────────────────────────────────────────────────────────────

print_help() {
  cat <<EOF
Usage: sh public/sh/sync-init.sh [OPTIONS]

Verify local public/zsh/init.zsh against the canonical GitHub raw main copy.
By default, reports mismatches only. Use --write to update the local file.

Options:
  --write                  Replace local file with remote (requires valid checksum)
  --local PATH             Local file to compare [default: public/zsh/init.zsh]
  --remote URL|PATH        Remote URL or local path [default: GitHub raw main]
  --checksum-url URL|PATH  Checksum URL or path [default: GitHub raw main checksum.txt]
  --no-checksum            Skip checksum validation of remote content
  --help                   Print this help and exit

Exit codes:
  0  Files match (or --write sync succeeded)
  1  Files differ, fetch error, or checksum mismatch
  2  Usage error
EOF
}

_fetch_url() {
  _url="$1"
  if command -v curl >/dev/null 2>&1; then
    command curl -fsSL "${_url}"
  elif command -v wget >/dev/null 2>&1; then
    command wget -qO- "${_url}"
  else
    printf '%b\n' "[1;31m▓▒░[0m No curl or wget available." >&2
    return 1
  fi
}

_legacy_url() {
  _url="$1"
  case "${_url}" in
  https://raw.githubusercontent.com/z-shell/src/main/public/*)
    printf '%s\n' "https://raw.githubusercontent.com/z-shell/src/main/lib/${_url#https://raw.githubusercontent.com/z-shell/src/main/public/}"
    ;;
  *)
    return 1
    ;;
  esac
}

# Fetch a URL or copy a local readable path to stdout.
_fetch() {
  _src="$1"
  _legacy_src=""
  _fetch_status=0
  case "${_src}" in
  http://* | https://*)
    set +e
    _fetch_url "${_src}"
    _fetch_status=$?
    set -e
    if [ "${_fetch_status}" -eq 0 ]; then
      return 0
    fi
    set +e
    _legacy_src="$(_legacy_url "${_src}" 2>/dev/null)"
    _legacy_status=$?
    set -e
    if [ "${_legacy_status}" -eq 0 ] && [ -n "${_legacy_src}" ]; then
      set +e
      _fetch_url "${_legacy_src}"
      _fetch_status=$?
      set -e
      if [ "${_fetch_status}" -eq 0 ]; then
        return 0
      fi
    fi
    printf '%b\n' "[1;31m▓▒░[0m Failed to fetch: ${_src}" >&2
    return 1
    ;;
  *)
    if [ -r "${_src}" ]; then
      command cat "${_src}"
    else
      printf '%b\n' "[1;31m▓▒░[0m Cannot read local path: ${_src}" >&2
      return 1
    fi
    ;;
  esac
}

# Compute SHA-256 hex digest of a file.
_sha256() {
  _file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${_file}" | command awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${_file}" | command awk '{print $1}'
  else
    printf '%b\n' "[1;31m▓▒░[0m No sha256sum or shasum available." >&2
    return 1
  fi
}

# ── Argument Parsing ──────────────────────────────────────────────────────────

while [ "$#" -gt 0 ]; do
  case "$1" in
  --write)
    OPT_WRITE=1
    shift
    ;;
  --local)
    [ "$#" -ge 2 ] || {
      printf '%s\n' "Error: --local requires an argument." >&2
      exit 2
    }
    OPT_LOCAL="$2"
    shift 2
    ;;
  --remote)
    [ "$#" -ge 2 ] || {
      printf '%s\n' "Error: --remote requires an argument." >&2
      exit 2
    }
    OPT_REMOTE="$2"
    shift 2
    ;;
  --checksum-url)
    [ "$#" -ge 2 ] || {
      printf '%s\n' "Error: --checksum-url requires an argument." >&2
      exit 2
    }
    OPT_CHECKSUM_URL="$2"
    shift 2
    ;;
  --no-checksum)
    OPT_NO_CHECKSUM=1
    shift
    ;;
  --help | -h)
    print_help
    exit 0
    ;;
  *)
    printf '%s\n' "Error: unknown option: $1" >&2
    exit 2
    ;;
  esac
done

# ── Validate Inputs ───────────────────────────────────────────────────────────

if [ ! -f "${OPT_LOCAL}" ] && [ "${OPT_WRITE}" -eq 0 ]; then
  printf '%b\n' "[1;31m▓▒░[0m Local file not found: ${OPT_LOCAL}" >&2
  printf '%b\n' "[1;33m▓▒░[0m Use --write to create it from remote." >&2
  exit 1
fi

# ── Fetch Remote ──────────────────────────────────────────────────────────────

REMOTE_FILE="${WORKDIR}/remote-init.zsh"
printf '%s\n' "▓▒░ Fetching remote: ${OPT_REMOTE}"
# shellcheck disable=SC2310
if ! _fetch "${OPT_REMOTE}" >"${REMOTE_FILE}"; then
  printf '%b\n' "[1;31m▓▒░[0m Failed to fetch remote file." >&2
  exit 1
fi

# ── Verify Remote Against Checksum ───────────────────────────────────────────

if [ "${OPT_NO_CHECKSUM}" -eq 0 ]; then
  CHECKSUM_FILE="${WORKDIR}/checksum.txt"
  printf '%s\n' "▓▒░ Fetching checksum: ${OPT_CHECKSUM_URL}"
  # shellcheck disable=SC2310
  if ! _fetch "${OPT_CHECKSUM_URL}" >"${CHECKSUM_FILE}"; then
    printf '%b\n' "[1;31m▓▒░[0m Failed to fetch checksum file." >&2
    exit 1
  fi

  EXPECTED_HASH="$(grep "${CHECKSUM_KEY}" "${CHECKSUM_FILE}" | command awk '{print $1}')"
  if [ -z "${EXPECTED_HASH}" ]; then
    printf '%b\n' "[1;31m▓▒░[0m No checksum entry for '${CHECKSUM_KEY}' in checksum.txt." >&2
    exit 1
  fi

  REMOTE_HASH="$(_sha256 "${REMOTE_FILE}")"
  if [ "${REMOTE_HASH}" != "${EXPECTED_HASH}" ]; then
    printf '%b\n' "[1;31m▓▒░[0m Remote checksum mismatch!" >&2
    printf '%s\n' "  expected : ${EXPECTED_HASH}" >&2
    printf '%s\n' "  got      : ${REMOTE_HASH}" >&2
    exit 1
  fi
  printf '%s\n' "▓▒░ Remote checksum verified: ${REMOTE_HASH}"
else
  REMOTE_HASH="$(_sha256 "${REMOTE_FILE}")"
  printf '%s\n' "▓▒░ Remote hash (checksum validation skipped): ${REMOTE_HASH}"
fi

# ── Compare ───────────────────────────────────────────────────────────────────

if [ -f "${OPT_LOCAL}" ]; then
  LOCAL_HASH="$(_sha256 "${OPT_LOCAL}")"
else
  LOCAL_HASH="(file not present)"
fi

if [ "${LOCAL_HASH}" = "${REMOTE_HASH}" ]; then
  printf '%b\n' "[1;32m▓▒░[0m Local file matches remote. No sync needed."
  printf '%s\n' "  hash : ${LOCAL_HASH}"
  printf '%s\n' "  path : ${OPT_LOCAL}"
  exit 0
fi

printf '%b\n' "[1;33m▓▒░[0m Local and remote differ."
printf '%s\n' "  local  : ${LOCAL_HASH}"
printf '%s\n' "  remote : ${REMOTE_HASH}"
printf '%s\n' "  source : ${OPT_REMOTE}"

if command -v diff >/dev/null 2>&1 && [ -f "${OPT_LOCAL}" ]; then
  printf '\n%s\n' "--- diff (local vs remote) ---"
  diff -u "${OPT_LOCAL}" "${REMOTE_FILE}" || true
  printf '%s\n' "--- end diff ---"
fi

# ── Sync ──────────────────────────────────────────────────────────────────────

if [ "${OPT_WRITE}" -eq 0 ]; then
  printf '\n%s\n' "▓▒░ Run with --write to replace the local file."
  exit 1
fi

LOCAL_DIR="$(dirname "${OPT_LOCAL}")"
TMP_TARGET="${LOCAL_DIR}/.sync-init.zsh.tmp.$$"

command cp "${REMOTE_FILE}" "${TMP_TARGET}"

if [ -f "${OPT_LOCAL}" ]; then
  ORIG_MODE="$(command stat -c '%a' "${OPT_LOCAL}" 2>/dev/null ||
    command stat -f '%A' "${OPT_LOCAL}" 2>/dev/null ||
    printf '755')"
  command chmod "${ORIG_MODE}" "${TMP_TARGET}"
else
  command chmod 755 "${TMP_TARGET}"
fi

command mv "${TMP_TARGET}" "${OPT_LOCAL}"

NEW_HASH="$(_sha256 "${OPT_LOCAL}")"
printf '%b\n' "[1;32m▓▒░[0m Sync complete."
printf '%s\n' "  before : ${LOCAL_HASH}"
printf '%s\n' "  after  : ${NEW_HASH}"
printf '%s\n' "  path   : ${OPT_LOCAL}"
