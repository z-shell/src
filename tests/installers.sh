#!/usr/bin/env sh
# -*- mode: sh; sh-indentation: 2; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: ft=sh sw=2 ts=2 et

set -eu

ROOT="$(
  unset CDPATH
  cd -- "$(dirname "$0")/.." && pwd
)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zi-test.XXXXXX")" || exit 1
trap 'rm -rf "${TMP_ROOT:?}"' EXIT INT TERM

fail() {
  printf '%s\n' "not ok - $*" >&2
  exit 1
}

pass() {
  printf '%s\n' "ok - $*"
}

contains() {
  file="$1"
  pattern="$2"
  if ! grep -F "${pattern}" "${file}" >/dev/null 2>&1; then
    printf '%s\n' "--- ${file} ---" >&2
    if [ -f "${file}" ]; then
      sed -n '1,120p' "${file}" >&2
    else
      printf '%s\n' "(missing)" >&2
    fi
    printf '%s\n' "--- end ${file} ---" >&2
    fail "${file} does not contain: ${pattern}"
  fi
}

sha256_file() {
  file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
  else
    fail "sha256sum or shasum is required"
  fi
}

check_syntax() {
  sh -n "${ROOT}/public/sh/install.sh"
  sh -n "${ROOT}/public/sh/install_zpmod.sh"
  sh -n "${ROOT}/public/sh/sync-init.sh"
  command -v zsh >/dev/null 2>&1 || fail "zsh is required for init.zsh syntax checks"
  zsh -n "${ROOT}/public/zsh/init.zsh"
  pass "script syntax"
}

check_checksums() {
  while read -r expected path; do
    [ -n "${expected}" ] || continue
    actual="$(sha256_file "${ROOT}/${path}")"
    [ "${actual}" = "${expected}" ] || fail "checksum mismatch for ${path}"
  done <"${ROOT}/public/checksum.txt"
  pass "checksums"
}

write_fake_tools() {
  FAKE_BIN="${TMP_ROOT}/bin"
  command mkdir -p "${FAKE_BIN}"

  cat >"${FAKE_BIN}/curl" <<'EOF'
#!/usr/bin/env sh
set -eu

out=""
remote_name=0
url=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      shift
      out="${1:-}"
      [ -n "${out}" ] || exit 64
      shift
      ;;
    -*O*)
      remote_name=1
      shift
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

[ -n "${url}" ] || { printf '%s\n' "curl test double: missing URL" >&2; exit 64; }
if [ -z "${out}" ] && [ "${remote_name}" -eq 1 ]; then
  out="${url##*/}"
fi

case "${url}" in
  */public/zsh/init.zsh)
    if [ -n "${out}" ]; then
      cp "${ZI_SRC_TEST_ROOT}/public/zsh/init.zsh" "${out}"
    else
      cat "${ZI_SRC_TEST_ROOT}/public/zsh/init.zsh"
    fi
    ;;
  */git-process-output.zsh)
    [ -n "${out}" ] || out="git-process-output.zsh"
    cat > "${out}" <<'SCRIPT'
#!/usr/bin/env sh
cat
SCRIPT
    chmod a+x "${out}"
    ;;
  */public/sh/install_zpmod.sh)
    [ -n "${out}" ] || { printf '%s\n' "curl test double: missing output path" >&2; exit 64; }
    cat > "${out}" <<'SCRIPT'
#!/usr/bin/env sh
set -eu
printf '%s\n' "zpmod fallback executed" > "${ZI_SRC_TEST_MARKER:?}"
SCRIPT
    chmod a+x "${out}"
    ;;
  *)
    printf '%s\n' "curl test double: unexpected URL ${url}" >&2
    exit 65
    ;;
esac
EOF

  cat >"${FAKE_BIN}/git" <<'EOF'
#!/usr/bin/env sh
set -eu

# Strip -C <dir> flag if present (used by install.sh to check remote URL)
if [ "${1:-}" = "-C" ]; then
  [ -n "${2:-}" ] || { printf '%s\n' "installers.sh git test double: -C requires a directory argument" >&2; exit 64; }
  shift 2
fi

cmd="${1:-}"
[ "$#" -gt 0 ] && shift

case "${cmd}" in
  clone)
    dest=""
    for arg do
      dest="${arg}"
    done
    [ -n "${dest}" ] || { printf '%s\n' "installers.sh git test double: missing clone destination" >&2; exit 64; }
    mkdir -p "${dest}/.git" "${dest}/lib"
    printf '%s\n' '# fake zi.zsh' > "${dest}/zi.zsh"
    printf '%s\n' '# fake _zi completion' > "${dest}/lib/_zi"
    ;;
  clean | reset | pull)
    ;;
  log)
    printf '%s\n' 'abcdef0 - fake zi commit (now) <test>'
    ;;
  remote)
    # After -C strip (if any) and cmd shift, $1/$2 hold the remote subcommand args
    if [ "${1:-}" != "get-url" ]; then
      printf '%s\n' "installers.sh git test double: expected remote subcommand 'get-url', got '${1:-<missing>}'" >&2
      exit 65
    fi
    if [ "${2:-}" != "origin" ]; then
      printf '%s\n' "installers.sh git test double: expected remote name 'origin', got '${2:-<missing>}'" >&2
      exit 65
    fi
    # Return a zi remote URL; override via ZI_SRC_TEST_FAKE_REMOTE env var
    printf '%s\n' "${ZI_SRC_TEST_FAKE_REMOTE:-https://github.com/z-shell/zi}"
    ;;
  *)
    printf '%s\n' "installers.sh git test double: unexpected command ${cmd}" >&2
    exit 65
    ;;
esac
EOF

  command chmod a+x "${FAKE_BIN}/curl" "${FAKE_BIN}/git"
}

test_loader_install() {
  home="${TMP_ROOT}/loader-home"
  config="${TMP_ROOT}/loader-config"
  data="${TMP_ROOT}/loader-data"
  command mkdir -p "${home}" "${config}" "${data}"

  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_CONFIG_HOME="${config}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -a loader -b feature/test >/dev/null

  # shellcheck disable=SC2016
  contains "${config}/zi/init.zsh" ': ${ZI[STREAM]:="feature/test"}'
  # shellcheck disable=SC2016
  contains "${home}/.zshrc" 'source "${XDG_CONFIG_HOME:-${HOME}/.config}/zi/init.zsh" && zzinit'
  [ -f "${data}/zi/bin/zi.zsh" ] || fail "loader install did not clone Zi into XDG data home"
  pass "loader install uses XDG paths and branch override"
}

test_xdg_data_home_install() {
  home="${TMP_ROOT}/default-home"
  data="${TMP_ROOT}/missing-root/data-home"
  command mkdir -p "${home}"

  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -i skip >/dev/null

  [ -f "${data}/zi/bin/zi.zsh" ] || fail "install did not create the XDG data home"
  pass "XDG data home install creates parent directories"
}

test_standalone_zpmod_delegation() {
  standalone_dir="${TMP_ROOT}/standalone"
  home="${TMP_ROOT}/zpmod-home"
  data="${TMP_ROOT}/zpmod-data"
  marker="${TMP_ROOT}/zpmod-marker"
  command mkdir -p "${standalone_dir}" "${home}" "${data}"
  command cp "${ROOT}/public/sh/install.sh" "${standalone_dir}/install.sh"

  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    ZI_SRC_TEST_MARKER="${marker}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${standalone_dir}/install.sh" -a zpmod -i skip >/dev/null

  contains "${marker}" 'zpmod fallback executed'
  pass "standalone install.sh fetches zpmod helper"
}

test_update_valid_zi_clone() {
  home="${TMP_ROOT}/update-valid-home"
  data="${TMP_ROOT}/update-valid-data"
  zi_bin="${data}/zi/bin"
  command mkdir -p "${home}" "${zi_bin}/.git"
  printf '%s\n' '# fake zi.zsh' >"${zi_bin}/zi.zsh"

  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -i skip >/dev/null

  pass "update path accepts a valid zi clone"
}

test_update_rejects_foreign_repo() {
  home="${TMP_ROOT}/update-foreign-home"
  data="${TMP_ROOT}/update-foreign-data"
  zi_bin="${data}/zi/bin"
  command mkdir -p "${home}" "${zi_bin}/.git"
  # Deliberately no zi.zsh: this simulates an unrelated git repo
  err="${TMP_ROOT}/update-foreign-err"

  set +e
  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -i skip >/dev/null 2>"${err}"
  exit_code="$?"
  set -e

  [ "${exit_code}" -ne 0 ] || fail "install.sh should have rejected a foreign git repository"
  contains "${err}" "does not appear to be a zi repository"
  pass "update path rejects an unrecognised git repository"
}

test_update_rejects_wrong_remote() {
  home="${TMP_ROOT}/update-wrong-remote-home"
  data="${TMP_ROOT}/update-wrong-remote-data"
  zi_bin="${data}/zi/bin"
  command mkdir -p "${home}" "${zi_bin}/.git"
  printf '%s\n' '# fake zi.zsh' >"${zi_bin}/zi.zsh"
  err="${TMP_ROOT}/update-wrong-remote-err"

  set +e
  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    ZI_SRC_TEST_FAKE_REMOTE="https://github.com/unrelated/project" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -i skip >/dev/null 2>"${err}"
  exit_code="$?"
  set -e

  [ "${exit_code}" -ne 0 ] || fail "install.sh should have rejected a repo with a non-zi remote"
  contains "${err}" "does not appear to be a zi repository"
  pass "update path rejects a repository with a non-zi remote origin"
}

test_sync_init() {
  local_file="${TMP_ROOT}/local-init.zsh"
  remote_file="${TMP_ROOT}/remote-init.zsh"
  checksum_file="${TMP_ROOT}/checksum.txt"

  printf '%s\n' '# remote init fixture' >"${remote_file}"
  command cp "${remote_file}" "${local_file}"
  remote_hash="$(sha256_file "${remote_file}")"
  printf '%s  %s\n' "${remote_hash}" 'public/zsh/init.zsh' >"${checksum_file}"

  sh "${ROOT}/public/sh/sync-init.sh" \
    --local "${local_file}" \
    --remote "${remote_file}" \
    --checksum-url "${checksum_file}" >/dev/null

  printf '%s\n' '# stale init fixture' >"${local_file}"
  if sh "${ROOT}/public/sh/sync-init.sh" \
    --local "${local_file}" \
    --remote "${remote_file}" \
    --checksum-url "${checksum_file}" >/dev/null 2>&1; then
    fail "sync-init mismatch check unexpectedly succeeded"
  fi

  sh "${ROOT}/public/sh/sync-init.sh" \
    --write \
    --local "${local_file}" \
    --remote "${remote_file}" \
    --checksum-url "${checksum_file}" >/dev/null

  cmp -s "${local_file}" "${remote_file}" || fail "sync-init --write did not replace local file"
  pass "sync-init fixtures"
}

check_syntax
check_checksums
write_fake_tools
test_loader_install
test_xdg_data_home_install
test_standalone_zpmod_delegation
test_update_valid_zi_clone
test_update_rejects_foreign_repo
test_update_rejects_wrong_remote
test_sync_init
