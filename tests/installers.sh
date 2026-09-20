#!/usr/bin/env sh
# -*- mode: sh; sh-indentation: 2; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: ft=sh sw=2 ts=2 et
# Fixture assertions intentionally combine captured output with surrounding
# predicates so each failed read fails the same test expression.
# shellcheck disable=SC2310,SC2312

set -eu

ROOT="$(
  unset CDPATH
  cd -- "$(dirname "$0")/.." && pwd
)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zi-test.XXXXXX")" || exit 1
trap 'rm -rf "${TMP_ROOT:?}"' EXIT INT TERM

# Keep fixture homes isolated from the caller's desktop environment. Individual
# tests set the XDG variables they exercise.
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME ZDOTDIR ZI_HOME ZI_BIN_DIR_NAME

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
  sh -n "${ROOT}/public/sh/setup.sh"
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

test_init_defaults_are_single_arguments() {
  capture_log="${TMP_ROOT}/init-default-arguments"
  values_log="${TMP_ROOT}/init-default-values"

  zsh -f -c '
    capture_colon() { print -r -- "argc:$#" >>"$CAPTURE_LOG"; }
    alias ":=capture_colon"
    setopt aliases sh_word_split
    typeset -A ZI
    ZI[REPOSITORY]="repository with spaces"
    export HOME="$4/home with spaces"
    export XDG_DATA_HOME="$4/data root"
    export XDG_CACHE_HOME="$4/cache root"
    export XDG_CONFIG_HOME="$4/config root"
    export XDG_STATE_HOME="$4/state root"
    export CAPTURE_LOG="$2"
    source "$1"
    {
      print -r -- "repository:${ZI[REPOSITORY]}"
      print -r -- "home:${ZI[HOME_DIR]}"
      print -r -- "history:${HISTFILE}"
    } >"$3"
  ' zsh "${ROOT}/public/zsh/init.zsh" "${capture_log}" "${values_log}" "${TMP_ROOT}"

  if grep -Fv 'argc:1' "${capture_log}" >/dev/null 2>&1; then
    fail "init defaults were split into multiple arguments under SH_WORD_SPLIT"
  fi
  contains "${values_log}" 'repository:repository with spaces'
  contains "${values_log}" "home:${TMP_ROOT}/data root/zi"
  contains "${values_log}" "history:${TMP_ROOT}/state root/zsh/history"
  pass "init defaults preserve argument and value boundaries"
}

test_init_preserves_caller_options() {
  values_log="${TMP_ROOT}/init-option-values"

  # zi.zsh's top level deliberately sets AUTO_CD and marks the path arrays
  # exported/unique. Wrapping the source in `emulate -L zsh` would localize
  # those to the loader's own function and silently discard them, so the loader
  # guards only the options that would corrupt parsing and restores the
  # caller's values afterwards.
  zsh -f -c '
    typeset -ghA ZI
    ZI[HOME_DIR]="$3/opt-home"
    ZI[BIN_DIR]="$3/opt-home/bin"
    ZI[CDPATH_DIR]="$3/opt-home/cd_path"
    command mkdir -p "${ZI[BIN_DIR]}" "${ZI[CDPATH_DIR]}"

    # A stand-in for zi.zsh that reproduces the two behaviours that matter:
    # it needs default word splitting, and its global effects must survive.
    print -r -- "
      typeset -g SAW_SPLIT=\${options[sh_word_split]}
      typeset -g SAW_KSHARRAYS=\${options[ksh_arrays]}
      builtin setopt auto_cd
      typeset -gxU path PATH
    " > "${ZI[BIN_DIR]}/zi.zsh"

    setopt sh_word_split ksh_arrays
    source "$1"
    zzinit

    {
      print -r -- "caller_split:${options[sh_word_split]}"
      print -r -- "caller_ksharrays:${options[ksh_arrays]}"
      print -r -- "inner_split:${SAW_SPLIT}"
      print -r -- "inner_ksharrays:${SAW_KSHARRAYS}"
      print -r -- "autocd:${options[autocd]}"
    } >"$2"
  ' zsh "${ROOT}/public/zsh/init.zsh" "${values_log}" "${TMP_ROOT}"

  # The caller keeps the options it had.
  contains "${values_log}" 'caller_split:on'
  contains "${values_log}" 'caller_ksharrays:on'
  # zi.zsh is sourced with sane parsing options regardless of the caller.
  contains "${values_log}" 'inner_split:off'
  contains "${values_log}" 'inner_ksharrays:off'
  # zi.zsh's intentional global effect survives the loader.
  contains "${values_log}" 'autocd:on'
  pass "loader guards parsing options without discarding Zi's global effects"
}

test_init_history_opt_out() {
  values_log="${TMP_ROOT}/init-history-values"
  history_home="${TMP_ROOT}/history-home"
  command mkdir -p "${history_home}"

  zsh -f -c '
    export HOME="$3"
    export XDG_STATE_HOME="$3/state"
    typeset -ghA ZI
    ZI[LOADER_HISTORY]=0
    source "$1"
    {
      print -r -- "histfile:${HISTFILE:-<unset>}"
      print -r -- "statedir:$([[ -d $XDG_STATE_HOME/zsh ]] && print present || print absent)"
    } >"$2"
  ' zsh "${ROOT}/public/zsh/init.zsh" "${values_log}" "${history_home}"

  contains "${values_log}" 'histfile:<unset>'
  contains "${values_log}" 'statedir:absent'
  pass "ZI[LOADER_HISTORY]=0 suppresses history defaults and filesystem writes"
}

test_init_rejects_invalid_stream() {
  values_log="${TMP_ROOT}/init-stream-values"
  err_log="${TMP_ROOT}/init-stream-err"

  # An option-like ZI[STREAM] must never reach `git clone --branch`.
  zsh -f -c '
    typeset -ghA ZI
    ZI[HOME_DIR]="$4/stream-home"
    ZI[BIN_DIR]="$4/stream-home/bin"
    ZI[STREAM]="--upload-pack=touch $4/stream-pwned"
    source "$1"
    zzinit 2>"$3"
    print -r -- "status:$?" >"$2"
    print -r -- "retryable:${+functions[zzinit]}" >>"$2"
  ' zsh "${ROOT}/public/zsh/init.zsh" "${values_log}" "${err_log}" "${TMP_ROOT}"

  contains "${values_log}" 'status:1'
  # A failed run keeps zzinit defined so the user can fix and retry.
  contains "${values_log}" 'retryable:1'
  contains "${err_log}" 'not a valid ref name'
  [ -e "${TMP_ROOT}/stream-pwned" ] && fail "invalid ZI[STREAM] reached git clone"
  pass "invalid ZI[STREAM] is rejected before reaching git"
}

test_init_keeps_helpers_when_zpmod_fails() {
  values_log="${TMP_ROOT}/init-zpmod-values"
  err_log="${TMP_ROOT}/init-zpmod-err"

  # zi.zsh loads, but an optional stage fails: zpmod.so exists and cannot be
  # loaded. The helpers and zzinit itself must survive so that, once the module
  # is rebuilt, the advertised `zzinit` retry has something to call.
  zsh -f -c '
    typeset -ghA ZI
    ZI[LOADER_HISTORY]=0
    ZI[HOME_DIR]="$4/zpmod-home"
    ZI[BIN_DIR]="$4/zpmod-home/bin"
    module_dir="${ZI[HOME_DIR]}/zmodules/zpmod/Src/zi"
    command mkdir -p "${ZI[BIN_DIR]}" "$module_dir"
    print -r -- "# fake zi.zsh" > "${ZI[BIN_DIR]}/zi.zsh"
    # A file that is not a shared object: zmodload refuses it.
    print -r -- "not a shared object" > "$module_dir/zpmod.so"

    source "$1"
    zzinit 2>"$3"
    print -r -- "first_status:$?" >"$2"
    print -r -- "first_retryable:${+functions[zzinit]}" >>"$2"

    command rm -f -- "$module_dir/zpmod.so"
    zzinit 2>>"$3"
    print -r -- "second_status:$?" >>"$2"
    print -r -- "second_retryable:${+functions[zzinit]}" >>"$2"
  ' zsh "${ROOT}/public/zsh/init.zsh" "${values_log}" "${err_log}" "${TMP_ROOT}"

  contains "${values_log}" 'first_status:1'
  contains "${err_log}" 'rebuild it with'
  # The failed run keeps zzinit defined so the user can rebuild and retry.
  contains "${values_log}" 'first_retryable:1'
  # The retry succeeds and only then removes the helpers.
  contains "${values_log}" 'second_status:0'
  contains "${values_log}" 'second_retryable:0'
  pass "optional zpmod failure keeps zzinit retryable"
}

test_init_progress_filter_url() {
  # The loader downloads this file and executes it. A 404 previously aborted
  # every clean install with no diagnostic, so the path is asserted here.
  contains "${ROOT}/public/zsh/init.zsh" \
    'https://raw.githubusercontent.com/z-shell/zi/main/lib/zsh/git-process-output.zsh'
  pass "progress filter URL points at the published path"
}

test_init_uses_private_tempdir() {
  # A fixed ${TMPDIR}/zi path would let another user pre-place the executable
  # that the loader downloads, chmods, and runs.
  if grep -F '${TMPDIR:-/tmp}/zi"' "${ROOT}/public/zsh/init.zsh" >/dev/null 2>&1; then
    fail "loader uses a predictable temporary directory"
  fi
  contains "${ROOT}/public/zsh/init.zsh" 'mktemp -d'
  pass "loader downloads the progress filter into a private temporary directory"
}

test_init_path_resolution() {
  values_log="${TMP_ROOT}/init-path-values"
  cases_root="${TMP_ROOT}/init path cases"
  command mkdir -p "${cases_root}"

  zsh -f -c '
    run_case() (
      builtin emulate -LR zsh
      local label="$1" root="$3/$1" expected_bin
      command mkdir -p "$root/home" "$root/zdotdir"
      typeset -gx HOME="$root/home"
      typeset -gx ZDOTDIR="$root/zdotdir"
      unset XDG_DATA_HOME XDG_CACHE_HOME XDG_CONFIG_HOME
      typeset -ghA ZI
      ZI=([LOADER_HISTORY]=0)

      case "$label" in
        fresh-spaces)
          typeset -gx XDG_DATA_HOME="$root/data root"
          ;;
        empty)
          typeset -gx XDG_DATA_HOME=""
          ;;
        relative)
          typeset -gx XDG_DATA_HOME="relative data"
          command mkdir -p "$ZDOTDIR/.zi/plugins"
          ;;
        legacy-only)
          command mkdir -p "$HOME/.zi/plugins"
          ;;
        xdg-only)
          typeset -gx XDG_DATA_HOME="$root/data"
          command mkdir -p "$XDG_DATA_HOME/zi/plugins"
          ;;
        both-external)
          typeset -gx XDG_DATA_HOME="$root/data"
          command mkdir -p "$HOME/.zi/plugins" "$XDG_DATA_HOME/zi/plugins"
          ;;
        both-xdg-source)
          typeset -gx XDG_DATA_HOME="$root/data"
          command mkdir -p "$HOME/.zi/plugins" "$XDG_DATA_HOME/zi/bin" "$XDG_DATA_HOME/zi/plugins"
          command touch "$XDG_DATA_HOME/zi/bin/zi.zsh"
          ZI[BIN_DIR]="$XDG_DATA_HOME/zi/bin"
          ;;
        explicit)
          typeset -gx XDG_DATA_HOME="$root/data"
          ZI[HOME_DIR]="$root/explicit home"
          ;;
      esac

      source "$2"
      print -r -- "$label|${ZI[HOME_DIR]}|${ZI[BIN_DIR]}|${ZI[HOME_LAYOUT]}|${ZI[CACHE_DIR]:-<unset>}|${ZI[CONFIG_DIR]:-<unset>}"
    )

    for label in fresh-spaces empty relative legacy-only xdg-only both-external both-xdg-source explicit; do
      run_case "$label" "$1" "$2"
    done
  ' zsh "${ROOT}/public/zsh/init.zsh" "${cases_root}" >"${values_log}"

  contains "${values_log}" "fresh-spaces|${cases_root}/fresh-spaces/data root/zi|${cases_root}/fresh-spaces/data root/zi/bin|xdg|<unset>|<unset>"
  contains "${values_log}" "empty|${cases_root}/empty/home/.local/share/zi|${cases_root}/empty/home/.local/share/zi/bin|xdg|<unset>|<unset>"
  contains "${values_log}" "relative|${cases_root}/relative/home/.local/share/zi|${cases_root}/relative/home/.local/share/zi/bin|xdg|<unset>|<unset>"
  contains "${values_log}" "legacy-only|${cases_root}/legacy-only/home/.zi|${cases_root}/legacy-only/home/.zi/bin|legacy|<unset>|<unset>"
  contains "${values_log}" "xdg-only|${cases_root}/xdg-only/data/zi|${cases_root}/xdg-only/data/zi/bin|xdg|<unset>|<unset>"
  contains "${values_log}" "both-external|${cases_root}/both-external/home/.zi|${cases_root}/both-external/home/.zi/bin|ambiguous-legacy|<unset>|<unset>"
  contains "${values_log}" "both-xdg-source|${cases_root}/both-xdg-source/data/zi|${cases_root}/both-xdg-source/data/zi/bin|ambiguous-xdg|<unset>|<unset>"
  contains "${values_log}" "explicit|${cases_root}/explicit/explicit home|${cases_root}/explicit/explicit home/bin|explicit|<unset>|<unset>"
  pass "loader mirrors the core home resolver and leaves cache and config to Zi"
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
[ -z "${ZI_SRC_TEST_CURL_LOG:-}" ] || printf '%s\n' "${url}" >>"${ZI_SRC_TEST_CURL_LOG}"
if [ -z "${out}" ] && [ "${remote_name}" -eq 1 ]; then
  out="${url##*/}"
fi

case "${url}" in
  */public/sh/install.sh)
    if [ -n "${out}" ]; then
      cp "${ZI_SRC_TEST_ROOT}/public/sh/install.sh" "${out}"
    else
      cat "${ZI_SRC_TEST_ROOT}/public/sh/install.sh"
    fi
    ;;
  */public/checksum.txt)
    [ -n "${out}" ] || { printf '%s\n' "curl test double: missing output path" >&2; exit 64; }
    cp "${ZI_SRC_TEST_ROOT}/public/checksum.txt" "${out}"
    ;;
  */public/sh/setup.sh)
    [ -n "${out}" ] || { printf '%s\n' "curl test double: missing output path" >&2; exit 64; }
    cp "${ZI_SRC_TEST_ROOT}/public/sh/setup.sh" "${out}"
    ;;
  */public/setup/profiles.tsv)
    [ -n "${out}" ] || { printf '%s\n' "curl test double: missing output path" >&2; exit 64; }
    cp "${ZI_SRC_TEST_ROOT}/public/setup/profiles.tsv" "${out}"
    ;;
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
[ -z "${ZI_SRC_TEST_GIT_LOG:-}" ] || printf '%s\n' "$*" >>"${ZI_SRC_TEST_GIT_LOG}"
[ "$#" -gt 0 ] && shift

case "${cmd}" in
  clone)
    dest=""
    for arg do
      dest="${arg}"
    done
    [ -n "${dest}" ] || { printf '%s\n' "installers.sh git test double: missing clone destination" >&2; exit 64; }
    if [ "${ZI_SRC_TEST_FAKE_CLONE_FAIL:-0}" -ne 0 ]; then
      printf '%s\n' "fatal: simulated clone failure" >&2
      exit 128
    fi
    mkdir -p "${dest}/.git" "${dest}/lib"
    printf '%s\n' '# fake zi.zsh' > "${dest}/zi.zsh"
    printf '%s\n' '# fake _zi completion' > "${dest}/lib/_zi"
    ;;
  check-ref-format)
    [ "${1:-}" = "--branch" ] || { printf '%s\n' "installers.sh git test double: expected --branch" >&2; exit 65; }
    case "${2:-}" in
      "" | -* | *:* | *..* | *[[:space:]]* | *~* | *^* | *\\* ) exit 1 ;;
    esac
    printf '%s\n' "$2"
    ;;
  fetch)
    ;;
  merge)
    if [ "${ZI_SRC_TEST_FAKE_FF_FAIL:-0}" -ne 0 ]; then
      printf '%s\n' "fatal: Not possible to fast-forward, aborting." >&2
      exit 128
    fi
    ;;
  status)
    printf '%s\n' "## main...origin/main [ahead 1]"
    printf '%s\n' " M zi.zsh"
    ;;
  rev-parse)
    [ "${1:-}" = "HEAD" ] || { printf '%s\n' "installers.sh git test double: expected rev-parse HEAD" >&2; exit 65; }
    printf '%s\n' "${ZI_SRC_TEST_FAKE_HEAD:-1111111111111111111111111111111111111111}"
    ;;
  symbolic-ref)
    [ "${1:-}" = "--quiet" ] && [ "${2:-}" = "--short" ] && [ "${3:-}" = "HEAD" ] || {
      printf '%s\n' "installers.sh git test double: unexpected symbolic-ref arguments" >&2
      exit 65
    }
    printf '%s\n' "${ZI_SRC_TEST_FAKE_BRANCH:-main}"
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

  cat >"${FAKE_BIN}/zsh" <<'EOF'
#!/usr/bin/env sh
set -eu

# The installer must never start an interactive shell: that would execute the
# user's own startup files with the installer's environment.
for arg; do
  case "${arg}" in
    -i | -i?* | -?*i?*)
      printf '%s\n' "zsh test double: interactive flag ${arg}" >&2
      exit 66
      ;;
  esac
  [ "${arg}" != "-c" ] || break
done
# Whatever the burst sources must not run compinit: it aborts without a tty.
for arg; do
  if [ -f "${arg}" ] && grep -q '^zicompinit' "${arg}" 2>/dev/null; then
    printf '%s\n' "zsh test double: burst sources zicompinit from ${arg}" >&2
    exit 67
  fi
done
[ -z "${ZI_SRC_TEST_ZSH_LOG:-}" ] || printf '%s\n' "zsh $*" >>"${ZI_SRC_TEST_ZSH_LOG}"
EOF

  command chmod a+x "${FAKE_BIN}/curl" "${FAKE_BIN}/git" "${FAKE_BIN}/zsh"
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
  contains "${config}/zi/init.zsh" ': "${ZI[STREAM]:=feature/test}"'
  contains "${home}/.zshrc" "source '${config}/zi/setup.zsh'"
  contains "${config}/zi/setup.zsh" "source '${config}/zi/setup/pre.zsh'"
  contains "${config}/zi/setup.zsh" "source '${config}/zi/init.zsh'"
  contains "${config}/zi/setup.zsh" '{ step=zzinit; zzinit; }'
  zsh -n "${config}/zi/setup.zsh"
  [ -f "${data}/zi/bin/zi.zsh" ] || fail "loader install did not clone Zi into XDG data home"
  pass "loader install uses XDG paths and branch override"
}

test_curl_pipe_install() {
  home="${TMP_ROOT}/curl-pipe-home"
  config="${TMP_ROOT}/curl-pipe-config"
  data="${TMP_ROOT}/curl-pipe-data"
  command mkdir -p "${home}"

  ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    curl -fsSL https://raw.githubusercontent.com/z-shell/src/main/public/sh/install.sh |
    HOME="${home}" \
      ZDOTDIR="${home}" \
      XDG_CONFIG_HOME="${config}" \
      XDG_DATA_HOME="${data}" \
      ZI_SRC_TEST_ROOT="${ROOT}" \
      PATH="${FAKE_BIN}:${PATH}" \
      sh >/dev/null

  [ -f "${data}/zi/bin/zi.zsh" ] || fail "curl-piped installer did not clone Zi"
  contains "${home}/.zshrc" "source '${config}/zi/setup.zsh'"
  contains "${config}/zi/setup.zsh" "source '${config}/zi/init.zsh'"
  pass "curl-piped install.sh fetches companion assets and installs Zi"
}

test_curl_pipe_install_keeps_asset_ref() {
  home="${TMP_ROOT}/curl-ref-home"
  config="${TMP_ROOT}/curl-ref-config"
  data="${TMP_ROOT}/curl-ref-data"
  curl_log="${TMP_ROOT}/curl-ref-log"
  src_ref="feature/208"
  command mkdir -p "${home}"

  ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    curl -fsSL "https://raw.githubusercontent.com/z-shell/src/${src_ref}/public/sh/install.sh" |
    HOME="${home}" \
      ZDOTDIR="${home}" \
      XDG_CONFIG_HOME="${config}" \
      XDG_DATA_HOME="${data}" \
      ZI_SRC_REF="${src_ref}" \
      ZI_SRC_TEST_CURL_LOG="${curl_log}" \
      ZI_SRC_TEST_ROOT="${ROOT}" \
      PATH="${FAKE_BIN}:${PATH}" \
      sh >/dev/null

  [ "$(wc -l <"${curl_log}" | tr -d ' ')" -eq 4 ] || fail "standalone installer fetched an unexpected number of companion assets"
  if grep -F '/main/public/' "${curl_log}" >/dev/null 2>&1; then
    fail "standalone installer mixed main assets with its requested source ref"
  fi
  contains "${curl_log}" "/${src_ref}/public/checksum.txt"
  contains "${curl_log}" "/${src_ref}/public/zsh/init.zsh"
  contains "${curl_log}" "/${src_ref}/public/sh/setup.sh"
  contains "${curl_log}" "/${src_ref}/public/setup/profiles.tsv"
  pass "curl-piped install.sh keeps companion assets on one source ref"
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

test_legacy_home_install() {
  home="${TMP_ROOT}/legacy-home"
  data="${TMP_ROOT}/legacy-data"
  command mkdir -p "${home}/.zi/plugins"

  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -i skip >/dev/null

  [ -f "${home}/.zi/bin/zi.zsh" ] || fail "installer did not retain the legacy Zi home"
  [ ! -e "${data}/zi/bin/zi.zsh" ] || fail "installer created a parallel XDG installation"
  pass "legacy-only install remains in the legacy Zi home"
}

test_relative_xdg_fallback_install() {
  home="${TMP_ROOT}/relative-home"
  work="${TMP_ROOT}/relative-work"
  command mkdir -p "${home}" "${work}"

  (
    cd "${work}" || exit 1
    HOME="${home}" \
      ZDOTDIR="${home}" \
      XDG_CONFIG_HOME="relative-config" \
      XDG_DATA_HOME="relative-data" \
      ZI_SRC_TEST_ROOT="${ROOT}" \
      PATH="${FAKE_BIN}:${PATH}" \
      sh "${ROOT}/public/sh/install.sh" -a loader -i skip >/dev/null
  )

  [ -f "${home}/.local/share/zi/bin/zi.zsh" ] || fail "relative XDG data value did not use fallback"
  [ -f "${home}/.config/zi/init.zsh" ] || fail "relative XDG config value did not use fallback"
  [ ! -e "${work}/relative-data" ] || fail "relative XDG data path was created"
  [ ! -e "${work}/relative-config" ] || fail "relative XDG config path was created"
  pass "relative XDG installer values use specification fallbacks"
}

test_both_present_install_identity() {
  home="${TMP_ROOT}/both-home"
  data="${TMP_ROOT}/both-data"
  command mkdir -p "${home}/.zi/plugins" "${data}/zi/bin/.git"
  printf '%s\n' '# fake zi.zsh' >"${data}/zi/bin/zi.zsh"

  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -i skip >/dev/null

  [ ! -e "${home}/.zi/bin" ] || fail "installer ignored the existing XDG source identity"
  [ -f "${data}/zi/bin/zi.zsh" ] || fail "installer did not retain the XDG source identity"
  pass "both-present installer selection follows existing source identity"
}

test_explicit_home_install() {
  home="${TMP_ROOT}/explicit-home"
  data="${TMP_ROOT}/explicit-data"
  explicit="${TMP_ROOT}/explicit Zi root"
  command mkdir -p "${home}" "${data}/zi/plugins"

  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${data}" \
    ZI_HOME="${explicit}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -i skip >/dev/null

  [ -f "${explicit}/bin/zi.zsh" ] || fail "explicit ZI_HOME was not preserved"
  pass "explicit installer home wins and preserves spaces"
}

test_standalone_zpmod_delegation() {
  standalone_dir="${TMP_ROOT}/standalone"
  home="${TMP_ROOT}/zpmod-home"
  data="${TMP_ROOT}/zpmod-data"
  marker="${TMP_ROOT}/zpmod-marker"
  command mkdir -p "${standalone_dir}" "${home}" "${data}"
  command cp "${ROOT}/public/sh/install.sh" "${standalone_dir}/install.sh"
  command cat >"${standalone_dir}/install_zpmod.sh" <<'EOF'
#!/usr/bin/env sh
set -eu
printf '%s\n' 'zpmod helper executed' >"${ZI_SRC_TEST_MARKER:?}"
EOF
  command chmod +x "${standalone_dir}/install_zpmod.sh"

  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    ZI_SRC_TEST_MARKER="${marker}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${standalone_dir}/install.sh" -a zpmod -i skip >/dev/null

  contains "${marker}" 'zpmod helper executed'
  pass "standalone install.sh delegates to its adjacent zpmod helper"
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
  contains "${err}" "has no zi.zsh"
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
  contains "${err}" "is not a z-shell/zi checkout"
  pass "update path rejects a repository with a non-zi remote origin"
}

test_update_fast_forwards_without_reset() {
  home="${TMP_ROOT}/update-ff-home"
  data="${TMP_ROOT}/update-ff-data"
  zi_bin="${data}/zi/bin"
  git_log="${TMP_ROOT}/update-ff-git-log"
  command mkdir -p "${home}" "${zi_bin}/.git"
  printf '%s\n' '# fake zi.zsh' >"${zi_bin}/zi.zsh"

  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    ZI_SRC_TEST_GIT_LOG="${git_log}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -i skip -b feature/test >/dev/null

  contains "${git_log}" 'fetch origin refs/heads/feature/test'
  contains "${git_log}" 'merge --ff-only FETCH_HEAD'
  if grep -E '^(clean|reset|pull)( |$)' "${git_log}" >/dev/null 2>&1; then
    fail "update path still discards local state (clean, reset, or pull was invoked)"
  fi
  pass "update path fetches and fast-forwards without discarding local state"
}

test_update_refuses_non_fast_forward() {
  home="${TMP_ROOT}/update-nonff-home"
  data="${TMP_ROOT}/update-nonff-data"
  zi_bin="${data}/zi/bin"
  err="${TMP_ROOT}/update-nonff-err"
  command mkdir -p "${home}" "${zi_bin}/.git"
  printf '%s\n' '# fake zi.zsh' >"${zi_bin}/zi.zsh"

  set +e
  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    ZI_SRC_TEST_FAKE_FF_FAIL=1 \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -i skip >/dev/null 2>"${err}"
  exit_code="$?"
  set -e

  [ "${exit_code}" -ne 0 ] || fail "install.sh should have refused a non-fast-forward update"
  contains "${err}" 'cannot be fast-forwarded'
  contains "${err}" 'local state was left untouched'
  contains "${err}" ' M zi.zsh'
  pass "update path refuses a non-fast-forward and shows the checkout state"
}

test_zshrc_comment_does_not_suppress_integration() {
  home="${TMP_ROOT}/probe-home"
  data="${TMP_ROOT}/probe-data"
  command mkdir -p "${home}"
  printf '%s\n' '# Zi is loaded from ~/.config/zi/init.zsh, see the wiki' >"${home}/.zshrc"

  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" >/dev/null

  contains "${home}/.zshrc" '# >>> zi setup >>>'
  contains "${home}/.zshrc" "source '${home}/.config/zi/setup.zsh'"
  pass "a comment mentioning init.zsh does not suppress the .zshrc integration"

  # An unrecognised real source line is left untouched and blocks apply.
  home2="${TMP_ROOT}/probe-home-sourced"
  data2="${TMP_ROOT}/probe-data-sourced"
  command mkdir -p "${home2}"
  # shellcheck disable=SC2016
  printf '%s\n' 'source "$HOME/.zi/bin/zi.zsh"' >"${home2}/.zshrc"
  before="$(sha256_file "${home2}/.zshrc")"

  err2="${TMP_ROOT}/probe-home-sourced-err"
  set +e
  HOME="${home2}" \
    ZDOTDIR="${home2}" \
    XDG_DATA_HOME="${data2}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" >/dev/null 2>"${err2}"
  exit_code="$?"
  set -e

  [ "${exit_code}" -ne 0 ] || fail "an unrecognised Zi source line was accepted"
  [ "$(sha256_file "${home2}/.zshrc")" = "${before}" ] || fail "an unrecognised Zi source line was modified"
  contains "${err2}" 'unrecognised Zi integration remains'
  pass "an unrecognised Zi source line is refused without mutation"
}

test_annex_rerun_is_idempotent() {
  home="${TMP_ROOT}/annex-home"
  data="${TMP_ROOT}/annex-data"
  zsh_log="${TMP_ROOT}/annex-zsh-log"
  shell_file="${home}/.config/zi/setup/shell.zsh"
  receipt="${home}/.config/zi/setup/receipt"
  command mkdir -p "${home}"

  for run in first second; do
    HOME="${home}" \
      ZDOTDIR="${home}" \
      XDG_DATA_HOME="${data}" \
      ZI_SRC_TEST_ROOT="${ROOT}" \
      ZI_SRC_TEST_ZSH_LOG="${zsh_log}" \
      PATH="${FAKE_BIN}:${PATH}" \
      sh "${ROOT}/public/sh/install.sh" -a annex >/dev/null || fail "annex install (${run} run) failed"
  done

  marker_lines="$(grep -c '^# >>> zi setup >>>$' "${home}/.zshrc")"
  [ "${marker_lines}" -eq 1 ] || fail "managed block appeared ${marker_lines} times across two runs"
  meta_lines="$(grep -c 'z-shell/z-a-meta-plugins' "${shell_file}")"
  [ "${meta_lines}" -eq 1 ] || fail "annex recipe appeared ${meta_lines} times across two runs"
  contains "${shell_file}" "zi ice ver'74bd8a8bc3bcff8398420ff5a38758dec5b90e2b'"
  contains "${shell_file}" '@annexes'
  contains "${shell_file}" 'zicompinit'
  contains "${receipt}" 'deferred-recipes=first-shell-start'
  [ ! -e "${zsh_log}" ] || fail "annex install executed Zsh during apply"
  pass "annex profile is idempotent and deferred to first shell start"
}

test_skip_leaves_annex_out() {
  home="${TMP_ROOT}/annex-skip-home"
  data="${TMP_ROOT}/annex-skip-data"
  zsh_log="${TMP_ROOT}/annex-skip-zsh-log"
  command mkdir -p "${home}"

  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    ZI_SRC_TEST_ZSH_LOG="${zsh_log}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -i skip -a annex >/dev/null

  [ ! -e "${home}/.zshrc" ] || fail "-i skip -a annex modified .zshrc"
  contains "${home}/.config/zi/setup/shell.zsh" '@annexes'
  [ ! -e "${zsh_log}" ] || fail "-i skip -a annex executed Zsh"
  pass "-i skip leaves .zshrc untouched even with an annex profile"
}

test_branch_option_rejects_refspec() {
  home="${TMP_ROOT}/branch-refspec-home"
  data="${TMP_ROOT}/branch-refspec-data"
  err="${TMP_ROOT}/branch-refspec-err"
  command mkdir -p "${home}"

  set +e
  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -i skip -b 'main:refs/heads/other' >/dev/null 2>"${err}"
  exit_code="$?"
  set -e

  [ "${exit_code}" -ne 0 ] || fail "install.sh accepted a refspec as -b"
  contains "${err}" 'invalid ref'
  [ ! -e "${data}/zi/bin/zi.zsh" ] || fail "install proceeded after an invalid -b value"
  pass "-b rejects values that are not a branch name"
}

test_source_ref_rejects_refspec() {
  home="${TMP_ROOT}/source-refspec-home"
  data="${TMP_ROOT}/source-refspec-data"
  err="${TMP_ROOT}/source-refspec-err"
  command mkdir -p "${home}"

  set +e
  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_REF='main:refs/heads/other' \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -i skip >/dev/null 2>"${err}"
  exit_code="$?"
  set -e

  [ "${exit_code}" -ne 0 ] || fail "install.sh accepted a refspec as ZI_SRC_REF"
  contains "${err}" 'Invalid ZI_SRC_REF'
  [ ! -e "${data}/zi/bin/zi.zsh" ] || fail "install proceeded after an invalid ZI_SRC_REF"
  pass "ZI_SRC_REF rejects values that are not a source ref"
}

test_zshrc_uses_short_entrypoint() {
  home="${TMP_ROOT}/home-text home"
  sibling="${TMP_ROOT}/home-text home-sibling"
  command mkdir -p "${home}"

  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${home}/xdg data" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" >/dev/null

  contains "${home}/.config/zi/setup/pre.zsh" "ZI[HOME_DIR]='${home}/xdg data/zi'"
  contains "${home}/.zshrc" "source '${home}/.config/zi/setup.zsh'"
  [ "$(wc -l <"${home}/.zshrc" | tr -d ' ')" -eq 3 ] || fail '.zshrc managed block is not three lines'
  if grep -F 'ZI_LOADER_CONFIG_HOME' "${home}/.zshrc" >/dev/null 2>&1; then
    fail '.zshrc exposes the internal loader configuration variable'
  fi
  pass 'the managed .zshrc block is one source line between ownership markers'

  home2="${TMP_ROOT}/home-text-2"
  command mkdir -p "${home2}"
  HOME="${home2}" \
    ZDOTDIR="${home2}" \
    ZI_HOME="${sibling}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" >/dev/null

  contains "${home2}/.config/zi/setup/pre.zsh" "ZI[HOME_DIR]='${sibling}'"
  # shellcheck disable=SC2016
  pass 'a sibling of $HOME remains an exact serialized path'
}

test_setup_describe_contract() {
  describe_home="${TMP_ROOT}/describe-home"
  describe_config="${TMP_ROOT}/describe-config"
  describe_data="${TMP_ROOT}/describe-data"
  describe_output="${TMP_ROOT}/describe-output"
  command mkdir -p "${describe_home}"
  printf '%s\n' '# existing startup content' >"${describe_home}/.zshrc"
  describe_before="$(sha256_file "${describe_home}/.zshrc")"

  HOME="${describe_home}" \
    ZDOTDIR="${describe_home}" \
    XDG_CONFIG_HOME="${describe_config}" \
    XDG_DATA_HOME="${describe_data}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/setup.sh" describe --output "${describe_output}" >/dev/null

  [ "$(cat "${describe_output}/format")" = zi-setup-describe-v1 ] || fail 'describe format is not versioned'
  [ "$(cat "${describe_output}/facts/zshrc-state/value")" = file ] || fail 'describe did not observe .zshrc'
  [ "$(cat "${describe_output}/facts/git/value")" = available ] || fail 'describe did not observe git'
  [ "$(cat "${describe_output}/facts/zsh/value")" = available ] || fail 'describe did not observe zsh'
  [ "$(cat "${describe_output}/profiles/loader/selectable")" = yes ] || fail 'loader is not selectable in a fresh home'
  [ "$(cat "${describe_output}/profiles/annex/selectable")" = yes ] || fail 'annex is not selectable in a fresh home'
  [ "$(sed -n '1p' "${describe_output}/profiles/order")" = loader ] || fail 'loader is not the first described profile'
  [ "$(sed -n '2p' "${describe_output}/profiles/order")" = annex ] || fail 'annex is not the second described profile'
  [ "$(wc -l <"${describe_output}/profiles/order" | tr -d ' ')" -eq 2 ] || fail 'fresh describe exposed an extra profile'
  [ "$(sha256_file "${describe_home}/.zshrc")" = "${describe_before}" ] || fail 'describe changed .zshrc'

  dangling_output="${TMP_ROOT}/describe-dangling-output"
  command ln -s "${TMP_ROOT}/describe-missing-target" "${dangling_output}"
  set +e
  HOME="${describe_home}" PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/setup.sh" describe --output "${dangling_output}" >/dev/null 2>&1
  dangling_status="$?"
  set -e
  [ "${dangling_status}" -eq 2 ] || fail "dangling output path exited ${dangling_status}, expected 2"
  [ -L "${dangling_output}" ] || fail 'describe replaced a dangling output symlink'

  zunit_home="${TMP_ROOT}/describe-zunit-home"
  zunit_output="${TMP_ROOT}/describe-zunit-output"
  command mkdir -p "${zunit_home}"
  command cat >"${zunit_home}/.zshrc" <<'EOF'
zi light-mode for \
  z-shell/z-a-meta-plugins \
  @annexes @zunit
EOF
  HOME="${zunit_home}" \
    ZDOTDIR="${zunit_home}" \
    XDG_CONFIG_HOME="${TMP_ROOT}/describe-zunit-config" \
    XDG_DATA_HOME="${TMP_ROOT}/describe-zunit-data" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/setup.sh" describe --output "${zunit_output}" >/dev/null
  contains "${zunit_output}/profiles/order" zunit
  [ "$(cat "${zunit_output}/profiles/zunit/selectable")" = no ] || fail 'legacy zunit became selectable'

  ambiguous_home="${TMP_ROOT}/describe-ambiguous-home"
  ambiguous_data="${TMP_ROOT}/describe-ambiguous-data"
  ambiguous_output="${TMP_ROOT}/describe-ambiguous-output"
  command mkdir -p "${ambiguous_home}/.zi/plugins" "${ambiguous_data}/zi/plugins"
  set +e
  HOME="${ambiguous_home}" \
    XDG_CONFIG_HOME="${TMP_ROOT}/describe-ambiguous-config" \
    XDG_DATA_HOME="${ambiguous_data}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/setup.sh" describe --output "${ambiguous_output}" >/dev/null
  describe_status="$?"
  set -e
  [ "${describe_status}" -eq 3 ] || fail "ambiguous discovery exited ${describe_status}, expected 3"
  [ "$(cat "${ambiguous_output}/facts/zi-home-state/value")" = ambiguous ] || fail 'ambiguous Zi homes were not represented'
  [ "$(cat "${ambiguous_output}/profiles/loader/selectable")" = no ] || fail 'ambiguous Zi homes produced an actionable profile'
  pass 'setup describe publishes bounded discovery and compatibility facts'
}

test_setup_plan_interface_metadata() {
  metadata_home="${TMP_ROOT}/metadata-home"
  metadata_config="${TMP_ROOT}/metadata-config"
  metadata_data="${TMP_ROOT}/metadata-data"
  metadata_plan_one="${TMP_ROOT}/metadata-plan-one"
  metadata_plan_two="${TMP_ROOT}/metadata-plan-two"
  metadata_result="${TMP_ROOT}/metadata-result"
  command mkdir -p "${metadata_home}"

  for metadata_plan in "${metadata_plan_one}" "${metadata_plan_two}"; do
    HOME="${metadata_home}" \
      XDG_CONFIG_HOME="${metadata_config}" \
      XDG_DATA_HOME="${metadata_data}" \
      PATH="${FAKE_BIN}:${PATH}" \
      sh "${ROOT}/public/sh/setup.sh" plan --plan "${metadata_plan}" --profile annex --skip-zshrc >/dev/null
  done

  [ "$(cat "${metadata_plan_one}/operations/order")" = "$(printf 'checkout-sync\nwrite-files')" ] || fail 'plan operation order is incomplete'
  [ "$(cat "${metadata_plan_one}/operations/checkout-sync/phase")" = checkout ] || fail 'checkout operation phase is invalid'
  [ "$(cat "${metadata_plan_one}/operations/write-files/phase")" = files ] || fail 'file operation phase is invalid'
  [ "$(cat "${metadata_plan_one}/warnings/deferred-first-start/severity")" = info ] || fail 'annex warning severity is invalid'
  [ "$(cat "${metadata_plan_one}/warnings/zshrc-skipped/severity")" = warning ] || fail 'skip warning severity is invalid'
  [ "$(cat "${metadata_plan_one}/plan.id")" = "$(cat "${metadata_plan_two}/plan.id")" ] || fail 'identical filesystem inputs produced different plan identities'

  printf '%s\n' 'tampered summary' >"${metadata_plan_one}/operations/write-files/summary"
  set +e
  sh "${ROOT}/public/sh/setup.sh" apply --plan "${metadata_plan_one}" --phase files --result "${metadata_result}" >/dev/null 2>&1
  metadata_status="$?"
  set -e
  [ "${metadata_status}" -eq 4 ] || fail "tampered operation metadata exited ${metadata_status}, expected 4"
  [ "$(cat "${metadata_result}/error/code")" = plan-changed ] || fail 'tampered operation metadata did not report plan-changed'
  [ ! -e "${metadata_result}/error/operation" ] || fail 'global plan failure named an operation'
  pass 'plan metadata is deterministic and covered by the reviewed hash'
}

test_setup_apply_result_contract() {
  result_home="${TMP_ROOT}/result-home"
  result_config="${TMP_ROOT}/result-config"
  result_data="${TMP_ROOT}/result-data"
  result_plan="${TMP_ROOT}/result-plan"
  result_output="${TMP_ROOT}/result-output"
  command mkdir -p "${result_home}"
  HOME="${result_home}" \
    XDG_CONFIG_HOME="${result_config}" \
    XDG_DATA_HOME="${result_data}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/setup.sh" plan --plan "${result_plan}" --skip-zshrc >/dev/null
  sh "${ROOT}/public/sh/setup.sh" apply --plan "${result_plan}" --phase files \
    --expect "$(cat "${result_plan}/plan.id")" --result "${result_output}" >/dev/null
  [ "$(cat "${result_output}/format")" = zi-setup-result-v1 ] || fail 'apply result format is not versioned'
  [ "$(cat "${result_output}/status")" = succeeded ] || fail 'successful files result is not succeeded'
  [ "$(cat "${result_output}/operations/write-files/status")" = succeeded ] || fail 'files operation is not succeeded'
  [ "$(cat "${result_output}/receipt/path")" = "${result_config}/zi/setup/receipt" ] || fail 'files result omitted the receipt path'

  drift_home="${TMP_ROOT}/result-drift-home"
  drift_config="${TMP_ROOT}/result-drift-config"
  drift_data="${TMP_ROOT}/result-drift-data"
  drift_plan="${TMP_ROOT}/result-drift-plan"
  drift_output="${TMP_ROOT}/result-drift-output"
  command mkdir -p "${drift_home}" "${drift_config}/zi"
  HOME="${drift_home}" XDG_CONFIG_HOME="${drift_config}" XDG_DATA_HOME="${drift_data}" \
    sh "${ROOT}/public/sh/setup.sh" plan --plan "${drift_plan}" --skip-zshrc >/dev/null
  printf '%s\n' drift >"${drift_config}/zi/init.zsh"
  set +e
  sh "${ROOT}/public/sh/setup.sh" apply --plan "${drift_plan}" --phase files --result "${drift_output}" >/dev/null 2>&1
  drift_result_status="$?"
  set -e
  [ "${drift_result_status}" -eq 4 ] || fail "target drift exited ${drift_result_status}, expected 4"
  [ "$(cat "${drift_output}/error/code")" = target-drift ] || fail 'target drift result has the wrong code'
  [ "$(cat "${drift_output}/error/operation")" = write-files ] || fail 'target drift result omitted its operation'

  lock_home="${TMP_ROOT}/result-lock-home"
  lock_config="${TMP_ROOT}/result-lock-config"
  lock_data="${TMP_ROOT}/result-lock-data"
  lock_plan="${TMP_ROOT}/result-lock-plan"
  lock_output="${TMP_ROOT}/result-lock-output"
  command mkdir -p "${lock_home}"
  HOME="${lock_home}" XDG_CONFIG_HOME="${lock_config}" XDG_DATA_HOME="${lock_data}" \
    sh "${ROOT}/public/sh/setup.sh" plan --plan "${lock_plan}" --skip-zshrc >/dev/null
  command mkdir -p "${lock_config}/zi.zi-setup.lock"
  set +e
  sh "${ROOT}/public/sh/setup.sh" apply --plan "${lock_plan}" --phase files --result "${lock_output}" >/dev/null 2>&1
  lock_result_status="$?"
  set -e
  [ "${lock_result_status}" -eq 4 ] || fail "held lock exited ${lock_result_status}, expected 4"
  [ "$(cat "${lock_output}/error/code")" = lock-held ] || fail 'held lock result has the wrong code'
  [ ! -e "${lock_output}/error/operation" ] || fail 'held lock named an operation that did not begin'

  network_home="${TMP_ROOT}/result-network-home"
  network_config="${TMP_ROOT}/result-network-config"
  network_data="${TMP_ROOT}/result-network-data"
  network_plan="${TMP_ROOT}/result-network-plan"
  network_output="${TMP_ROOT}/result-network-output"
  command mkdir -p "${network_home}"
  HOME="${network_home}" XDG_CONFIG_HOME="${network_config}" XDG_DATA_HOME="${network_data}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/setup.sh" plan --plan "${network_plan}" --skip-zshrc >/dev/null
  set +e
  ZI_SRC_TEST_FAKE_CLONE_FAIL=1 PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/setup.sh" apply --plan "${network_plan}" --phase checkout --result "${network_output}" >/dev/null 2>&1
  network_result_status="$?"
  set -e
  [ "${network_result_status}" -eq 5 ] || fail "network failure exited ${network_result_status}, expected 5"
  [ "$(cat "${network_output}/error/code")" = network-failed ] || fail 'network failure result has the wrong code'
  [ "$(cat "${network_output}/error/operation")" = checkout-sync ] || fail 'network failure result omitted its operation'
  pass 'apply publishes stable success and failure result artifacts'
}

test_setup_plan_tamper_is_rejected() {
  tamper_home="${TMP_ROOT}/tamper-home"
  tamper_config="${TMP_ROOT}/tamper-config"
  tamper_data="${TMP_ROOT}/tamper-data"
  tamper_plan="${TMP_ROOT}/tamper-plan"
  tamper_err="${TMP_ROOT}/tamper-err"
  command mkdir -p "${tamper_home}"

  HOME="${tamper_home}" \
    XDG_CONFIG_HOME="${tamper_config}" \
    XDG_DATA_HOME="${tamper_data}" \
    sh "${ROOT}/public/sh/setup.sh" plan --plan "${tamper_plan}" --skip-zshrc >/dev/null
  printf '%s\n' '# tampered' >>"${tamper_plan}/targets/pre/content"

  set +e
  sh "${ROOT}/public/sh/setup.sh" apply --plan "${tamper_plan}" --phase files >/dev/null 2>"${tamper_err}"
  tamper_status="$?"
  set -e

  [ "${tamper_status}" -ne 0 ] || fail "setup.sh applied a tampered plan"
  contains "${tamper_err}" 'plan artifact hash mismatch'
  [ ! -e "${tamper_config}/zi" ] || fail "tampered plan created configuration files"
  pass "setup rejects a plan whose exact content changed"
}

test_setup_target_drift_is_transactional() {
  drift_home="${TMP_ROOT}/drift-home"
  drift_config="${TMP_ROOT}/drift-config"
  drift_data="${TMP_ROOT}/drift-data"
  drift_plan="${TMP_ROOT}/drift-plan"
  drift_err="${TMP_ROOT}/drift-err"
  command mkdir -p "${drift_home}" "${drift_config}/zi"

  HOME="${drift_home}" \
    XDG_CONFIG_HOME="${drift_config}" \
    XDG_DATA_HOME="${drift_data}" \
    sh "${ROOT}/public/sh/setup.sh" plan --plan "${drift_plan}" --skip-zshrc >/dev/null
  printf '%s\n' '# appeared after planning' >"${drift_config}/zi/init.zsh"

  set +e
  sh "${ROOT}/public/sh/setup.sh" apply --plan "${drift_plan}" --phase files >/dev/null 2>"${drift_err}"
  drift_status="$?"
  set -e

  [ "${drift_status}" -ne 0 ] || fail "setup.sh ignored target drift"
  contains "${drift_err}" 'target changed after planning'
  contains "${drift_config}/zi/init.zsh" '# appeared after planning'
  [ ! -e "${drift_config}/zi/setup/pre.zsh" ] || fail "target drift caused a partial pre.zsh write"
  [ ! -e "${drift_config}/zi/setup/shell.zsh" ] || fail "target drift caused a partial shell.zsh write"
  [ ! -e "${drift_config}/zi/setup.zsh" ] || fail "target drift caused a partial setup.zsh write"
  pass "file apply validates every precondition before mutation"
}

test_setup_symlinked_zshrc_is_refused() {
  symlink_home="${TMP_ROOT}/symlink-home"
  symlink_config="${TMP_ROOT}/symlink-config"
  symlink_data="${TMP_ROOT}/symlink-data"
  symlink_plan="${TMP_ROOT}/symlink-plan"
  symlink_target="${TMP_ROOT}/symlink-target-zshrc"
  symlink_err="${TMP_ROOT}/symlink-err"
  command mkdir -p "${symlink_home}"
  printf '%s\n' '# real startup file' >"${symlink_target}"
  command ln -s "${symlink_target}" "${symlink_home}/.zshrc"
  symlink_before="$(sha256_file "${symlink_target}")"

  HOME="${symlink_home}" \
    ZDOTDIR="${symlink_home}" \
    XDG_CONFIG_HOME="${symlink_config}" \
    XDG_DATA_HOME="${symlink_data}" \
    sh "${ROOT}/public/sh/setup.sh" plan --plan "${symlink_plan}" >/dev/null

  set +e
  sh "${ROOT}/public/sh/setup.sh" apply --plan "${symlink_plan}" --phase files >/dev/null 2>"${symlink_err}"
  symlink_status="$?"
  set -e

  [ "${symlink_status}" -ne 0 ] || fail "setup.sh replaced a symlinked .zshrc"
  contains "${symlink_err}" 'refusing symlink target'
  contains "${symlink_err}" '# >>> zi setup >>>'
  [ -L "${symlink_home}/.zshrc" ] || fail "setup.sh replaced the .zshrc symlink itself"
  [ "$(sha256_file "${symlink_target}")" = "${symlink_before}" ] || fail "setup.sh changed the symlink target"
  [ ! -e "${symlink_config}/zi" ] || fail "symlink refusal caused partial configuration writes"
  pass "symlinked .zshrc is refused with a patch and no mutation"
}

test_setup_managed_block_drift_is_refused() {
  managed_home="${TMP_ROOT}/managed-home"
  managed_config="${TMP_ROOT}/managed-config"
  managed_data="${TMP_ROOT}/managed-data"
  managed_plan_one="${TMP_ROOT}/managed-plan-one"
  managed_plan_two="${TMP_ROOT}/managed-plan-two"
  managed_err="${TMP_ROOT}/managed-err"
  command mkdir -p "${managed_home}"

  HOME="${managed_home}" \
    ZDOTDIR="${managed_home}" \
    XDG_CONFIG_HOME="${managed_config}" \
    XDG_DATA_HOME="${managed_data}" \
    sh "${ROOT}/public/sh/setup.sh" plan --plan "${managed_plan_one}" >/dev/null
  sh "${ROOT}/public/sh/setup.sh" apply --plan "${managed_plan_one}" --phase files >/dev/null
  command sed 's|/setup.zsh|/user-change.zsh|' \
    "${managed_home}/.zshrc" >"${managed_home}/.zshrc.changed"
  command mv "${managed_home}/.zshrc.changed" "${managed_home}/.zshrc"
  managed_before="$(sha256_file "${managed_home}/.zshrc")"

  set +e
  HOME="${managed_home}" \
    ZDOTDIR="${managed_home}" \
    XDG_CONFIG_HOME="${managed_config}" \
    XDG_DATA_HOME="${managed_data}" \
    sh "${ROOT}/public/sh/setup.sh" plan --plan "${managed_plan_two}" >/dev/null 2>"${managed_err}"
  managed_status="$?"
  set -e

  [ "${managed_status}" -ne 0 ] || fail "setup.sh accepted an externally changed managed block"
  contains "${managed_err}" 'managed .zshrc block changed outside Zi setup'
  [ "$(sha256_file "${managed_home}/.zshrc")" = "${managed_before}" ] || fail "managed block refusal changed .zshrc"
  [ ! -e "${managed_plan_two}" ] || fail "managed block refusal published a plan"
  pass "managed .zshrc drift requires manual reconciliation"
}

test_setup_checkout_head_drift_is_refused() {
  checkout_home="${TMP_ROOT}/checkout-drift-home"
  checkout_config="${TMP_ROOT}/checkout-drift-config"
  checkout_data="${TMP_ROOT}/checkout-drift-data"
  checkout_path="${checkout_data}/zi/bin"
  checkout_plan="${TMP_ROOT}/checkout-drift-plan"
  checkout_err="${TMP_ROOT}/checkout-drift-err"
  checkout_log="${TMP_ROOT}/checkout-drift-log"
  command mkdir -p "${checkout_home}" "${checkout_path}/.git"
  printf '%s\n' '# fake zi.zsh' >"${checkout_path}/zi.zsh"

  HOME="${checkout_home}" \
    XDG_CONFIG_HOME="${checkout_config}" \
    XDG_DATA_HOME="${checkout_data}" \
    ZI_SRC_TEST_FAKE_HEAD=1111111111111111111111111111111111111111 \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/setup.sh" plan --plan "${checkout_plan}" --skip-zshrc >/dev/null
  : >"${checkout_log}"

  set +e
  ZI_SRC_TEST_FAKE_HEAD=2222222222222222222222222222222222222222 \
    ZI_SRC_TEST_GIT_LOG="${checkout_log}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/setup.sh" apply --plan "${checkout_plan}" --phase checkout >/dev/null 2>"${checkout_err}"
  checkout_status="$?"
  set -e

  [ "${checkout_status}" -ne 0 ] || fail "setup.sh updated a checkout whose HEAD drifted"
  contains "${checkout_err}" 'checkout HEAD changed after planning'
  if grep -E '^(fetch|merge)( |$)' "${checkout_log}" >/dev/null 2>&1; then
    fail "checkout drift reached a mutating git operation"
  fi
  pass "checkout apply validates the planned HEAD before fetch"
}

write_legacy_direct_fixture() {
  legacy_file="$1"
  legacy_home="$2"
  legacy_bin="$3"
  legacy_ref="$4"
  legacy_profile="$5"
  command cat >"${legacy_file}" <<EOF
if [[ ! -f ${legacy_home}/${legacy_bin}/zi.zsh ]]; then
  print -P "%F{33}▓▒░ %F{160}Installing (%F{33}z-shell/zi%F{160})…%f"
  command mkdir -p "${legacy_home}" && command chmod go-rwX "${legacy_home}"
  command git clone -q --filter=blob:none --single-branch --branch "${legacy_ref}" https://github.com/z-shell/zi "${legacy_home}/${legacy_bin}" && \\
    print -P "%F{33}▓▒░ %F{34}Installation successful.%f%b" || \\
    print -P "%F{160}▓▒░ The clone has failed.%f%b"
fi
source "${legacy_home}/${legacy_bin}/zi.zsh"
autoload -Uz _zi
(( \${+_comps} )) && _comps[zi]=_zi
# examples here -> https://wiki.zshell.dev/ecosystem/category/-annexes
zicompinit # <- https://wiki.zshell.dev/docs/guides/commands
EOF
  case "${legacy_profile}" in
  annex)
    command cat >>"${legacy_file}" <<'EOF'
zi light-mode for \
  z-shell/z-a-meta-plugins \
  @annexes # <- https://wiki.zshell.dev/ecosystem/category/-annexes
# examples here -> https://wiki.zshell.dev/community/gallery/collection
zicompinit # <- https://wiki.zshell.dev/docs/guides/commands
EOF
    ;;
  zunit)
    command cat >>"${legacy_file}" <<'EOF'
zi light-mode for \
  z-shell/z-a-meta-plugins \
  @annexes @zunit
EOF
    ;;
  *) fail "unknown legacy profile fixture ${legacy_profile}" ;;
  esac
}

test_setup_legacy_profiles_migrate() {
  for legacy_profile in annex zunit; do
    legacy_home_dir="${TMP_ROOT}/legacy-${legacy_profile}-home"
    legacy_config="${TMP_ROOT}/legacy-${legacy_profile}-config"
    legacy_data="${TMP_ROOT}/legacy-${legacy_profile}-data"
    legacy_plan="${TMP_ROOT}/legacy-${legacy_profile}-plan"
    legacy_checkout="${TMP_ROOT}/legacy ${legacy_profile}'s checkout"
    legacy_bin="custom bin"
    legacy_ref="feature/legacy-${legacy_profile}"
    legacy_values="${TMP_ROOT}/legacy-${legacy_profile}-values"
    command mkdir -p "${legacy_home_dir}"
    write_legacy_direct_fixture "${legacy_home_dir}/.zshrc" "${legacy_checkout}" "${legacy_bin}" "${legacy_ref}" "${legacy_profile}"

    HOME="${legacy_home_dir}" \
      ZDOTDIR="${legacy_home_dir}" \
      XDG_CONFIG_HOME="${legacy_config}" \
      XDG_DATA_HOME="${legacy_data}" \
      PATH="${FAKE_BIN}:${PATH}" \
      sh "${ROOT}/public/sh/setup.sh" plan --plan "${legacy_plan}" >/dev/null
    sh "${ROOT}/public/sh/setup.sh" apply --plan "${legacy_plan}" --phase files >/dev/null

    contains "${legacy_home_dir}/.zshrc" '# >>> zi setup >>>'
    if grep -F 'command git clone' "${legacy_home_dir}/.zshrc" >/dev/null 2>&1; then
      fail "legacy ${legacy_profile} direct block remained in .zshrc"
    fi
    if grep -F 'z-shell/z-a-meta-plugins' "${legacy_home_dir}/.zshrc" >/dev/null 2>&1; then
      fail "legacy ${legacy_profile} recipe remained in .zshrc"
    fi
    contains "${legacy_config}/zi/setup/shell.zsh" "@${legacy_profile}"
    contains "${legacy_config}/zi/setup/shell.zsh" "ver'74bd8a8bc3bcff8398420ff5a38758dec5b90e2b'"
    zsh -f -c '
      source "$1"
      print -r -- "home:${ZI[HOME_DIR]}"
      print -r -- "bin:${ZI[BIN_DIR]}"
      print -r -- "stream:${ZI[STREAM]}"
    ' zsh "${legacy_config}/zi/setup/pre.zsh" >"${legacy_values}"
    contains "${legacy_values}" "home:${legacy_checkout}"
    contains "${legacy_values}" "bin:${legacy_checkout}/${legacy_bin}"
    contains "${legacy_values}" "stream:${legacy_ref}"
  done
  pass "legacy direct, annex, and zunit profiles migrate without evaluation"
}

test_setup_legacy_loader_discovers_checkout() {
  loader_migration_home="${TMP_ROOT}/loader-migration-home"
  loader_migration_config="${TMP_ROOT}/loader-migration-config"
  loader_migration_data="${TMP_ROOT}/loader-migration-data"
  loader_migration_plan="${TMP_ROOT}/loader-migration-plan"
  loader_migration_err="${TMP_ROOT}/loader-migration-err"
  command mkdir -p "${loader_migration_home}/.zi/bin/.git"
  printf '%s\n' '# fake zi.zsh' >"${loader_migration_home}/.zi/bin/zi.zsh"
  command cat >"${loader_migration_home}/.zshrc" <<'EOF'
if [[ -n ${XDG_CONFIG_HOME:-} && ${XDG_CONFIG_HOME} == /* ]]; then
  ZI_LOADER_CONFIG_HOME="${XDG_CONFIG_HOME}/zi"
else
  ZI_LOADER_CONFIG_HOME="${HOME}/.config/zi"
fi
if [[ -r "${ZI_LOADER_CONFIG_HOME}/init.zsh" ]]; then
  source "${ZI_LOADER_CONFIG_HOME}/init.zsh" && zzinit
fi
unset ZI_LOADER_CONFIG_HOME
EOF

  HOME="${loader_migration_home}" \
    ZDOTDIR="${loader_migration_home}" \
    XDG_CONFIG_HOME="${loader_migration_config}" \
    XDG_DATA_HOME="${loader_migration_data}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/setup.sh" plan --plan "${loader_migration_plan}" >/dev/null
  contains "${loader_migration_plan}/plan.meta" "checkout_path=${loader_migration_home}/.zi/bin"
  sh "${ROOT}/public/sh/setup.sh" apply --plan "${loader_migration_plan}" --phase files >/dev/null
  contains "${loader_migration_home}/.zshrc" '# >>> zi setup >>>'
  # shellcheck disable=SC2016
  if grep -F 'if [[ -r "${ZI_LOADER_CONFIG_HOME}/init.zsh" ]]' "${loader_migration_home}/.zshrc" >/dev/null 2>&1; then
    fail "legacy loader block remained after migration"
  fi

  command mkdir -p "${loader_migration_data}/zi/bin/.git"
  printf '%s\n' '# second fake zi.zsh' >"${loader_migration_data}/zi/bin/zi.zsh"
  set +e
  HOME="${loader_migration_home}" \
    ZDOTDIR="${loader_migration_home}" \
    XDG_CONFIG_HOME="${loader_migration_config}" \
    XDG_DATA_HOME="${loader_migration_data}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/setup.sh" plan --plan "${TMP_ROOT}/loader-migration-conflict-plan" >/dev/null 2>"${loader_migration_err}"
  loader_migration_status="$?"
  set -e

  [ "${loader_migration_status}" -ne 0 ] || fail "setup.sh chose between ambiguous loader checkouts"
  contains "${loader_migration_err}" 'both legacy and XDG Zi homes exist'
  pass "legacy loader migration discovers one checkout and refuses conflicts"
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

test_loader_default_paths_remain_dynamic() {
  home="${TMP_ROOT}/loader-dynamic-home"
  config="${TMP_ROOT}/loader-dynamic-config"
  data="${TMP_ROOT}/loader-dynamic-data"
  command mkdir -p "${home}" "${config}" "${data}"

  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_CONFIG_HOME="${config}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -a loader >/dev/null

  if grep -F 'ZI[HOME_DIR]=' "${home}/.zshrc" >/dev/null 2>&1; then
    fail "managed .zshrc embedded a checkout path"
  fi
  contains "${config}/zi/setup/pre.zsh" "ZI[HOME_DIR]='${data}/zi'"
  pass "default loader path is isolated in the generated pre fragment"
}

test_loader_carries_explicit_paths() {
  home="${TMP_ROOT}/loader-explicit-home"
  config="${TMP_ROOT}/loader explicit config's root"
  data="${TMP_ROOT}/loader-explicit-data"
  explicit="${TMP_ROOT}/loader explicit's root"
  bin_name="custom \$(touch pwned) ' bin"
  runtime_work="${TMP_ROOT}/loader-runtime-work"
  values_log="${TMP_ROOT}/loader-explicit-values"
  command mkdir -p "${home}" "${config}" "${data}" "${runtime_work}"

  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_CONFIG_HOME="${config}" \
    XDG_DATA_HOME="${data}" \
    ZI_HOME="${explicit}" \
    ZI_BIN_DIR_NAME="${bin_name}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -a loader >/dev/null

  [ -f "${explicit}/${bin_name}/zi.zsh" ] || fail "loader install did not use the explicit checkout path"
  contains "${config}/zi/setup.zsh" 'typeset -gA ZI'

  (
    cd "${runtime_work}" || exit 1
    HOME="${home}" \
      XDG_CONFIG_HOME="${TMP_ROOT}/unrelated-runtime-config" \
      XDG_DATA_HOME="${data}" \
      zsh -f -c '
        source "$1"
        print -r -- "home:${ZI[HOME_DIR]}"
        print -r -- "bin:${ZI[BIN_DIR]}"
        print -r -- "layout:${ZI[HOME_LAYOUT]}"
      ' zsh "${home}/.zshrc"
  ) >"${values_log}"

  contains "${values_log}" "home:${explicit}"
  contains "${values_log}" "bin:${explicit}/${bin_name}"
  contains "${values_log}" 'layout:explicit'
  contains "${home}/.zshrc" "source '${TMP_ROOT}/loader explicit config'\\''s root/zi/setup.zsh'"
  [ ! -e "${runtime_work}/pwned" ] || fail "explicit loader path executed generated Zsh"
  [ ! -e "${data}/zi/bin/zi.zsh" ] || fail "loader startup cloned a second checkout"
  pass "loader carries explicit home and bin paths into startup safely"
}

test_loader_carries_explicit_bin_name() {
  home="${TMP_ROOT}/loader-bin-home"
  config="${TMP_ROOT}/loader-bin-config"
  data="${TMP_ROOT}/loader-bin-data"
  bin_name="custom bin"
  values_log="${TMP_ROOT}/loader-bin-values"
  command mkdir -p "${home}" "${config}" "${data}"

  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_CONFIG_HOME="${config}" \
    XDG_DATA_HOME="${data}" \
    ZI_BIN_DIR_NAME="${bin_name}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -a loader >/dev/null

  HOME="${home}" \
    XDG_CONFIG_HOME="${config}" \
    XDG_DATA_HOME="${data}" \
    zsh -f -c '
      source "$1"
      print -r -- "home:${ZI[HOME_DIR]}"
      print -r -- "bin:${ZI[BIN_DIR]}"
    ' zsh "${home}/.zshrc" >"${values_log}"

  contains "${values_log}" "home:${data}/zi"
  contains "${values_log}" "bin:${data}/zi/${bin_name}"
  [ ! -e "${data}/zi/bin/zi.zsh" ] || fail "custom bin startup cloned into the default bin"
  pass "loader carries an explicit bin name with the resolved home"
}

test_relative_installer_paths_are_rejected() {
  zdot_home="${TMP_ROOT}/relative-zdot-home"
  zdot_config="${TMP_ROOT}/relative-zdot-config"
  zdot_data="${TMP_ROOT}/relative-zdot-data"
  zdot_work="${TMP_ROOT}/relative-zdot-work"
  zdot_err="${TMP_ROOT}/relative-zdot-err"
  command mkdir -p "${zdot_home}" "${zdot_work}"

  set +e
  (
    cd "${zdot_work}" || exit 1
    HOME="${zdot_home}" \
      ZDOTDIR="relative-zdotdir" \
      XDG_CONFIG_HOME="${zdot_config}" \
      XDG_DATA_HOME="${zdot_data}" \
      ZI_SRC_TEST_ROOT="${ROOT}" \
      PATH="${FAKE_BIN}:${PATH}" \
      sh "${ROOT}/public/sh/install.sh" -a loader >/dev/null 2>"${zdot_err}"
  )
  exit_code="$?"
  set -e

  [ "${exit_code}" -ne 0 ] || fail "install.sh accepted a relative ZDOTDIR"
  contains "${zdot_err}" 'ZDOTDIR must be an absolute path when set: relative-zdotdir'
  [ ! -e "${zdot_config}" ] || fail "relative ZDOTDIR rejection wrote loader configuration"
  [ ! -e "${zdot_data}" ] || fail "relative ZDOTDIR rejection created a checkout"
  [ ! -e "${zdot_work}/relative-zdotdir" ] || fail "relative ZDOTDIR rejection created the relative path"

  zi_home="${TMP_ROOT}/relative-zi-home"
  zi_config="${TMP_ROOT}/relative-zi-config"
  zi_data="${TMP_ROOT}/relative-zi-data"
  zi_work="${TMP_ROOT}/relative-zi-work"
  zi_err="${TMP_ROOT}/relative-zi-err"
  command mkdir -p "${zi_home}" "${zi_work}"

  set +e
  (
    cd "${zi_work}" || exit 1
    HOME="${zi_home}" \
      ZDOTDIR="${zi_home}" \
      XDG_CONFIG_HOME="${zi_config}" \
      XDG_DATA_HOME="${zi_data}" \
      ZI_HOME="relative-zi-root" \
      ZI_SRC_TEST_ROOT="${ROOT}" \
      PATH="${FAKE_BIN}:${PATH}" \
      sh "${ROOT}/public/sh/install.sh" -a loader >/dev/null 2>"${zi_err}"
  )
  exit_code="$?"
  set -e

  [ "${exit_code}" -ne 0 ] || fail "install.sh accepted a relative ZI_HOME"
  contains "${zi_err}" 'ZI_HOME must be an absolute path when set: relative-zi-root'
  [ ! -e "${zi_config}" ] || fail "relative ZI_HOME rejection wrote loader configuration"
  [ ! -e "${zi_data}" ] || fail "relative ZI_HOME rejection created a default checkout"
  [ ! -e "${zi_work}/relative-zi-root" ] || fail "relative ZI_HOME rejection created the relative checkout"
  pass "relative ZDOTDIR and ZI_HOME are rejected before persistent mutation"
}

test_success_line_reports_exact_path() {
  home="${TMP_ROOT}/success-home"
  data="${TMP_ROOT}/success-data"
  output="${TMP_ROOT}/success-output"
  plain_output="${TMP_ROOT}/success-output-plain"
  command mkdir -p "${home}"

  HOME="${home}" \
    ZDOTDIR="${home}" \
    XDG_DATA_HOME="${data}" \
    ZI_SRC_TEST_ROOT="${ROOT}" \
    PATH="${FAKE_BIN}:${PATH}" \
    sh "${ROOT}/public/sh/install.sh" -i skip >"${output}"

  awk '{
    gsub(sprintf("%c", 27) "\\[[0-9;]*m", "")
    print
  }' "${output}" >"${plain_output}"
  success_line="$(grep 'Successfully installed at ' "${plain_output}")"
  reported_path="${success_line#*Successfully installed at }"
  [ "${reported_path}" = "${data}/zi/bin" ] ||
    fail "success line reported ${reported_path} instead of ${data}/zi/bin"
  pass "success line reports the exact installation path"
}

check_syntax
check_checksums
test_init_defaults_are_single_arguments
test_init_preserves_caller_options
test_init_history_opt_out
test_init_rejects_invalid_stream
test_init_keeps_helpers_when_zpmod_fails
test_init_progress_filter_url
test_init_uses_private_tempdir
test_init_path_resolution
write_fake_tools
test_loader_install
test_curl_pipe_install
test_curl_pipe_install_keeps_asset_ref
test_loader_default_paths_remain_dynamic
test_loader_carries_explicit_paths
test_loader_carries_explicit_bin_name
test_relative_installer_paths_are_rejected
test_xdg_data_home_install
test_legacy_home_install
test_relative_xdg_fallback_install
test_both_present_install_identity
test_explicit_home_install
test_standalone_zpmod_delegation
test_update_valid_zi_clone
test_update_rejects_foreign_repo
test_update_rejects_wrong_remote
test_update_fast_forwards_without_reset
test_update_refuses_non_fast_forward
test_zshrc_comment_does_not_suppress_integration
test_annex_rerun_is_idempotent
test_skip_leaves_annex_out
test_branch_option_rejects_refspec
test_source_ref_rejects_refspec
test_zshrc_uses_short_entrypoint
test_setup_describe_contract
test_setup_plan_interface_metadata
test_setup_apply_result_contract
test_setup_plan_tamper_is_rejected
test_setup_target_drift_is_transactional
test_setup_symlinked_zshrc_is_refused
test_setup_managed_block_drift_is_refused
test_setup_checkout_head_drift_is_refused
test_setup_legacy_profiles_migrate
test_setup_legacy_loader_discovers_checkout
test_sync_init
test_success_line_reports_exact_path
