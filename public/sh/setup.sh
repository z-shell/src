#!/usr/bin/env sh
# -*- mode: sh; sh-indentation: 2; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: ft=sh sw=2 ts=2 et

set -eu

PROGRAM="${0##*/}"
SCRIPT_DIR="$(
  unset CDPATH
  cd "$(dirname "$0")" 2>/dev/null && pwd
)" || exit 1
ROOT="$(
  unset CDPATH
  cd "${SCRIPT_DIR}/../.." 2>/dev/null && pwd
)" || exit 1

die() {
  printf '%s\n' "${PROGRAM}: $*" >&2
  exit 1
}

usage() {
  command cat <<'EOF'
Usage:
  setup.sh plan --plan DIR [--profile loader|annex|zunit] [--ref REF]
                [--zi-home DIR] [--zi-bin-dir NAME] [--config-home DIR]
                [--zshrc FILE] [--init FILE] [--profiles FILE]
                [--checksum FILE] [--skip-zshrc]
  setup.sh apply --plan DIR --phase checkout|files [--expect SHA256]
EOF
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

is_absolute_path() {
  case "${1-}" in
  /*) return 0 ;;
  *) return 1 ;;
  esac
}

validate_text_path() {
  case "$2" in
  *"
"* | *"	"*) die "$1 must not contain a newline or tab" ;;
  esac
}

validate_ref() {
  case "$1" in
  "" | -* | *..* | *[!A-Za-z0-9._/-]*)
    die "invalid ref '$1': use ASCII letters, digits, '.', '_', '/', or '-', with no leading '-' or '..'"
    ;;
  esac
  command git check-ref-format --branch "$1" >/dev/null 2>&1 ||
    die "invalid ref '$1': not a valid branch name"
}

zsh_single_quote() {
  _zsh_quote_value="$(printf '%s' "$1" | command sed "s/'/'\\\\''/g")" ||
    die 'failed to serialize a Zsh string'
  printf "'%s'" "${_zsh_quote_value}"
}

zi_home_has_installation() {
  [ -f "$1/bin/zi.zsh" ] ||
    [ -d "$1/plugins" ] ||
    [ -d "$1/snippets" ] ||
    [ -d "$1/completions" ] ||
    [ -d "$1/zmodules" ]
}

resolve_zi_home() {
  if [ -n "${ZI_HOME-}" ]; then
    printf '%s\n' "${ZI_HOME}"
    return
  fi
  if is_absolute_path "${XDG_DATA_HOME-}"; then
    _resolve_data="${XDG_DATA_HOME}"
  else
    _resolve_data="${HOME}/.local/share"
  fi
  _resolve_legacy="${HOME}/.zi"
  _resolve_xdg="${_resolve_data}/zi"
  _resolve_legacy_present=0
  _resolve_xdg_present=0
  zi_home_has_installation "${_resolve_legacy}" && _resolve_legacy_present=1
  zi_home_has_installation "${_resolve_xdg}" && _resolve_xdg_present=1
  if [ "${_resolve_legacy_present}" -eq 1 ] && [ "${_resolve_xdg_present}" -eq 1 ]; then
    if [ -f "${_resolve_xdg}/bin/zi.zsh" ] && [ ! -f "${_resolve_legacy}/bin/zi.zsh" ]; then
      printf '%s\n' "${_resolve_xdg}"
    else
      die "both legacy and XDG Zi homes exist; pass --zi-home to select one"
    fi
  elif [ "${_resolve_legacy_present}" -eq 1 ]; then
    printf '%s\n' "${_resolve_legacy}"
  else
    printf '%s\n' "${_resolve_xdg}"
  fi
}

current_hash() {
  if [ -e "$1" ]; then
    sha256_file "$1"
  else
    printf '%s\n' missing
  fi
}

receipt_value() {
  _receipt_key="$1"
  _receipt_file="$2"
  [ -f "${_receipt_file}" ] || return 1
  [ "$(sed -n '1p' "${_receipt_file}")" = 'format=zi-setup-receipt-v1' ] || return 1
  sed -n "s/^${_receipt_key}=//p" "${_receipt_file}" | sed -n '1p'
}

profile_revision() {
  _profile_label="$1"
  _profile_file="$2"
  _profile_value="$(awk -v label="${_profile_label}" '
    $1 == label { if (seen++) exit 2; print $2 }
  ' "${_profile_file}")" || die "duplicate profile label ${_profile_label}"
  case "${_profile_value}" in
  "" | *[!0-9a-f]*) die "profile label ${_profile_label} is missing a pinned revision" ;;
  esac
  [ "${#_profile_value}" -eq 40 ] || die "profile label ${_profile_label} must use a full 40-character revision"
  printf '%s\n' "${_profile_value}"
}

artifact_hash() (
  _artifact_dir="$1"
  _artifact_raw="$(mktemp "${TMPDIR:-/tmp}/zi-setup-hash-raw.XXXXXX")" || exit 1
  _artifact_list="$(mktemp "${TMPDIR:-/tmp}/zi-setup-hash-list.XXXXXX")" || {
    command rm -f "${_artifact_raw}"
    exit 1
  }
  _artifact_manifest="$(mktemp "${TMPDIR:-/tmp}/zi-setup-hash-manifest.XXXXXX")" || {
    command rm -f "${_artifact_raw}" "${_artifact_list}"
    exit 1
  }
  trap 'rm -f "${_artifact_raw}" "${_artifact_list}" "${_artifact_manifest}"' EXIT INT TERM
  cd "${_artifact_dir}" || exit 1
  find . -type f ! -name plan.id -print >"${_artifact_raw}" || exit 1
  LC_ALL=C sort "${_artifact_raw}" >"${_artifact_list}" || exit 1
  while IFS= read -r _artifact_file; do
    _artifact_file_hash="$(sha256_file "${_artifact_file}")" || exit 1
    printf '%s  %s\n' "${_artifact_file_hash}" "${_artifact_file}" >>"${_artifact_manifest}" || exit 1
  done <"${_artifact_list}"
  sha256_file "${_artifact_manifest}"
)

plan_value() {
  _plan_key="$1"
  _plan_dir="$2"
  sed -n "s/^${_plan_key}=//p" "${_plan_dir}/plan.meta" | sed -n '1p'
}

write_managed_block() {
  _managed_config_home="$1"
  _managed_entry_text="$(zsh_single_quote "${_managed_config_home}/setup.zsh")" ||
    die 'failed to serialize the setup entrypoint'
  command cat <<EOF
# >>> zi setup >>>
source ${_managed_entry_text}
# <<< zi setup <<<
EOF
}

write_setup_entrypoint() {
  _entry_config_home="$1"
  _entry_pre_text="$(zsh_single_quote "${_entry_config_home}/setup/pre.zsh")" ||
    die 'failed to serialize the pre-setup path'
  _entry_init_text="$(zsh_single_quote "${_entry_config_home}/init.zsh")" ||
    die 'failed to serialize the init path'
  _entry_shell_text="$(zsh_single_quote "${_entry_config_home}/setup/shell.zsh")" ||
    die 'failed to serialize the shell-setup path'
  command cat <<EOF
# Generated by Zi guided setup. Edit choices through a new plan.
() {
  typeset -gA ZI
  local step=setup/pre.zsh
  if source ${_entry_pre_text} && \
    { step=init.zsh; source ${_entry_init_text}; } && \
    { step=zzinit; zzinit; }; then
    step=setup/shell.zsh
    source ${_entry_shell_text} || print -u2 -- "Zi setup: \${step} failed"
  else
    print -u2 -- "Zi setup: \${step} failed"
  fi
}
EOF
}

write_legacy_loader() {
  command cat <<'EOF'
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
}

write_legacy_loader_explicit() {
  _legacy_home="$1"
  _legacy_bin="$2"
  _legacy_home_text="$(zsh_single_quote "${_legacy_home}")" || die 'failed to serialize the legacy Zi home'
  _legacy_bin_text="$(zsh_single_quote "${_legacy_home}/${_legacy_bin}")" || die 'failed to serialize the legacy Zi bin path'
  command cat <<EOF
if [[ -n \${XDG_CONFIG_HOME:-} && \${XDG_CONFIG_HOME} == /* ]]; then
  ZI_LOADER_CONFIG_HOME="\${XDG_CONFIG_HOME}/zi"
else
  ZI_LOADER_CONFIG_HOME="\${HOME}/.config/zi"
fi
typeset -gA ZI
ZI[HOME_DIR]=${_legacy_home_text}
ZI[BIN_DIR]=${_legacy_bin_text}
if [[ -r "\${ZI_LOADER_CONFIG_HOME}/init.zsh" ]]; then
  source "\${ZI_LOADER_CONFIG_HOME}/init.zsh" && zzinit
fi
unset ZI_LOADER_CONFIG_HOME
EOF
}

write_legacy_direct() {
  _legacy_home="$1"
  _legacy_bin="$2"
  _legacy_ref="$3"
  # The literal $HOME text is intentional in the generated legacy template.
  # shellcheck disable=SC2016
  case "${_legacy_home}" in
  "${HOME}") _legacy_text='$HOME' ;;
  "${HOME}"/*) _legacy_text="\$HOME${_legacy_home#"${HOME}"}" ;;
  *) _legacy_text="${_legacy_home}" ;;
  esac
  command cat <<EOF
if [[ ! -f ${_legacy_text}/${_legacy_bin}/zi.zsh ]]; then
  print -P "%F{33}▓▒░ %F{160}Installing (%F{33}z-shell/zi%F{160})…%f"
  command mkdir -p "${_legacy_text}" && command chmod go-rwX "${_legacy_text}"
  command git clone -q --filter=blob:none --single-branch --branch "${_legacy_ref}" https://github.com/z-shell/zi "${_legacy_text}/${_legacy_bin}" && \\
    print -P "%F{33}▓▒░ %F{34}Installation successful.%f%b" || \\
    print -P "%F{160}▓▒░ The clone has failed.%f%b"
fi
source "${_legacy_text}/${_legacy_bin}/zi.zsh"
autoload -Uz _zi
(( \${+_comps} )) && _comps[zi]=_zi
# examples here -> https://wiki.zshell.dev/ecosystem/category/-annexes
zicompinit # <- https://wiki.zshell.dev/docs/guides/commands
EOF
}

write_legacy_annex() {
  command cat <<'EOF'
zi light-mode for \
  z-shell/z-a-meta-plugins \
  @annexes # <- https://wiki.zshell.dev/ecosystem/category/-annexes
# examples here -> https://wiki.zshell.dev/community/gallery/collection
zicompinit # <- https://wiki.zshell.dev/docs/guides/commands
EOF
}

write_legacy_zunit() {
  command cat <<'EOF'
zi light-mode for \
  z-shell/z-a-meta-plugins \
  @annexes @zunit
EOF
}

extract_legacy_direct_values() {
  _extract_file="$1"
  LEGACY_DIRECT_FOUND=0
  [ -f "${_extract_file}" ] || return 0
  _extract_source_count="$(grep -Ec '^[[:space:]]*source "[^"\\]*/zi\.zsh"$' "${_extract_file}" 2>/dev/null || true)"
  _extract_clone_count="$(grep -Ec '^[[:space:]]*command git clone .*--branch "[A-Za-z0-9._/-]+" https://github.com/z-shell/zi ' "${_extract_file}" 2>/dev/null || true)"
  [ "${_extract_source_count}" -ne 0 ] && [ "${_extract_clone_count}" -ne 0 ] || return 0
  [ "${_extract_source_count}" -eq 1 ] || die 'legacy direct profile has more than one candidate source line'
  [ "${_extract_clone_count}" -eq 1 ] || die 'legacy direct profile ref cannot be decoded unambiguously'
  _extract_source="$(grep -E '^[[:space:]]*source "[^"\\]*/zi\.zsh"$' "${_extract_file}")"
  _extract_path="${_extract_source#*source \"}"
  _extract_path="${_extract_path%/zi.zsh\"}"
  # These patterns intentionally match literal shell syntax without evaluating it.
  # shellcheck disable=SC2016
  case "${_extract_path}" in
  *'`'* | *'$('* | *'${'*) die 'legacy direct profile path cannot be decoded unambiguously' ;;
  '$HOME') _extract_path="${HOME}" ;;
  '$HOME'/*) _extract_path="${HOME}${_extract_path#\$HOME}" ;;
  /*) ;;
  *) die 'legacy direct profile path is neither absolute nor rooted at $HOME' ;;
  esac
  _extract_bin="${_extract_path##*/}"
  _extract_home="${_extract_path%/*}"
  case "${_extract_bin}" in "" | . | .. | */*) die 'legacy direct profile bin name is ambiguous' ;; esac
  is_absolute_path "${_extract_home}" || die 'legacy direct profile home is not absolute after decoding'

  _extract_clone="$(grep -E '^[[:space:]]*command git clone .*--branch "[A-Za-z0-9._/-]+" https://github.com/z-shell/zi ' "${_extract_file}")"
  _extract_ref_part="${_extract_clone#*--branch \"}"
  _extract_ref="${_extract_ref_part%%\"*}"
  validate_ref "${_extract_ref}"

  LEGACY_DIRECT_FOUND=1
  LEGACY_DIRECT_HOME="${_extract_home}"
  LEGACY_DIRECT_BIN="${_extract_bin}"
  LEGACY_DIRECT_REF="${_extract_ref}"
}

strip_exact_block() {
  _strip_source="$1"
  _strip_template="$2"
  _strip_output="$3"
  _strip_result="$4"
  awk -v result="${_strip_result}" '
    FNR == NR { template[++template_count] = $0; next }
    { source[++source_count] = $0 }
    END {
      matches = 0
      start = 0
      for (i = 1; i <= source_count - template_count + 1; i++) {
        equal = 1
        for (j = 1; j <= template_count; j++) {
          if (source[i + j - 1] != template[j]) { equal = 0; break }
        }
        if (equal) { matches++; start = i }
      }
      print matches > result
      for (i = 1; i <= source_count; i++) {
        if (matches == 1 && i >= start && i < start + template_count) continue
        print source[i]
      }
    }
  ' "${_strip_template}" "${_strip_source}" >"${_strip_output}"
}

replace_managed_block() {
  _replace_source="$1"
  _replace_block="$2"
  _replace_output="$3"
  awk -v block_file="${_replace_block}" '
    $0 == "# >>> zi setup >>>" {
      while ((getline block_line < block_file) > 0) print block_line
      close(block_file)
      skipping = 1
      next
    }
    skipping && $0 == "# <<< zi setup <<<" { skipping = 0; next }
    !skipping { print }
  ' "${_replace_source}" >"${_replace_output}"
}

extract_managed_block() {
  awk '
    $0 == "# >>> zi setup >>>" { copying = 1 }
    copying { print }
    $0 == "# <<< zi setup <<<" { copying = 0 }
  ' "$1" >"$2"
}

diff_target() {
  _diff_path="$1"
  _diff_content="$2"
  _diff_empty="$3"
  if [ -e "${_diff_path}" ]; then
    diff -u "${_diff_path}" "${_diff_content}" || [ "$?" -eq 1 ]
  else
    : >"${_diff_empty}"
    diff -u "${_diff_empty}" "${_diff_content}" || [ "$?" -eq 1 ]
  fi
}

add_target() {
  _target_plan="$1"
  _target_id="$2"
  _target_path="$3"
  _target_content="$4"
  _target_mode="$5"
  _target_receipt="$6"
  _target_dir="${_target_plan}/targets/${_target_id}"
  command mkdir -p "${_target_dir}"
  command cp "${_target_content}" "${_target_dir}/content"
  printf '%s\n' "${_target_path}" >"${_target_dir}/path"
  printf '%s\n' "${_target_mode}" >"${_target_dir}/mode"
  _target_kind='missing'
  if [ -L "${_target_path}" ]; then
    _target_kind='symlink'
  elif [ -e "${_target_path}" ]; then
    _target_kind='file'
  fi
  printf '%s\n' "${_target_kind}" >"${_target_dir}/kind"
  _target_expected="$(current_hash "${_target_path}")"
  printf '%s\n' "${_target_expected}" >"${_target_dir}/expected"

  if [ "${_target_kind}" = file ] && [ "${_target_id}" != zshrc ]; then
    _target_desired="$(sha256_file "${_target_content}")"
    if [ "${_target_expected}" != "${_target_desired}" ]; then
      _target_owned="$(receipt_value "target.${_target_id}" "${_target_receipt}" 2>/dev/null || true)"
      [ "${_target_owned}" = "${_target_expected}" ] ||
        die "refusing unmanaged target ${_target_path}; move it aside or restore a valid receipt"
    fi
  fi
  printf '%s\n' "${_target_id}" >>"${_target_plan}/targets/order"
}

write_shell_fragment() {
  _shell_profile="$1"
  _shell_direct="$2"
  _shell_profiles="$3"
  _shell_output="$4"
  {
    printf '%s\n' '# Generated by Zi guided setup. Edit choices through a new plan.'
    if [ "${_shell_direct}" -eq 1 ] || [ "${_shell_profile}" != loader ]; then
      command cat <<'EOF'
autoload -Uz _zi
(( ${+_comps} )) && _comps[zi]=_zi
EOF
    fi
    case "${_shell_profile}" in
    loader)
      printf '%s\n' ': # no post-loader recipe selected'
      ;;
    annex | zunit)
      _shell_revision="$(profile_revision annexes "${_shell_profiles}")"
      printf '%s\n' "zi ice ver'${_shell_revision}'"
      # The trailing backslashes are literal continuation markers in generated Zsh.
      # shellcheck disable=SC1003
      printf '%s\n' 'zi light-mode for \' '  z-shell/z-a-meta-plugins \'
      if [ "${_shell_profile}" = annex ]; then
        printf '%s\n' '  @annexes # <- https://wiki.zshell.dev/ecosystem/category/-annexes'
      else
        _shell_zunit_revision="$(profile_revision zunit "${_shell_profiles}")"
        [ "${_shell_zunit_revision}" = "${_shell_revision}" ] ||
          die "annexes and zunit must share one verified meta-plugins revision"
        printf '%s\n' '  @annexes @zunit'
      fi
      printf '%s\n' 'zicompinit # <- https://wiki.zshell.dev/docs/guides/commands'
      ;;
    esac
  } >"${_shell_output}"
}

plan_command() {
  PLAN_DIR=""
  PROFILE=loader
  REF=main
  PLAN_ZI_HOME="${ZI_HOME-}"
  PLAN_HOME_EXPLICIT=0
  [ -z "${ZI_HOME-}" ] || PLAN_HOME_EXPLICIT=1
  PLAN_BIN="${ZI_BIN_DIR_NAME:-bin}"
  PLAN_BIN_EXPLICIT=0
  [ -z "${ZI_BIN_DIR_NAME-}" ] || PLAN_BIN_EXPLICIT=1
  REF_EXPLICIT=0
  CONFIG_HOME=""
  ZSHRC_PATH=""
  INIT_SOURCE="${ROOT}/public/zsh/init.zsh"
  PROFILES_FILE="${ROOT}/public/setup/profiles.tsv"
  CHECKSUM_FILE="${ROOT}/public/checksum.txt"
  SKIP_ZSHRC=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
    --plan)
      [ "$#" -ge 2 ] || die '--plan requires a directory'
      PLAN_DIR="$2"
      shift 2
      ;;
    --profile)
      [ "$#" -ge 2 ] || die '--profile requires a value'
      PROFILE="$2"
      shift 2
      ;;
    --ref)
      [ "$#" -ge 2 ] || die '--ref requires a value'
      REF="$2"
      REF_EXPLICIT=1
      shift 2
      ;;
    --zi-home)
      [ "$#" -ge 2 ] || die '--zi-home requires a directory'
      PLAN_ZI_HOME="$2"
      PLAN_HOME_EXPLICIT=1
      shift 2
      ;;
    --zi-bin-dir)
      [ "$#" -ge 2 ] || die '--zi-bin-dir requires a name'
      PLAN_BIN="$2"
      PLAN_BIN_EXPLICIT=1
      shift 2
      ;;
    --config-home)
      [ "$#" -ge 2 ] || die '--config-home requires a directory'
      CONFIG_HOME="$2"
      shift 2
      ;;
    --zshrc)
      [ "$#" -ge 2 ] || die '--zshrc requires a file'
      ZSHRC_PATH="$2"
      shift 2
      ;;
    --init)
      [ "$#" -ge 2 ] || die '--init requires a file'
      INIT_SOURCE="$2"
      shift 2
      ;;
    --profiles)
      [ "$#" -ge 2 ] || die '--profiles requires a file'
      PROFILES_FILE="$2"
      shift 2
      ;;
    --checksum)
      [ "$#" -ge 2 ] || die '--checksum requires a file'
      CHECKSUM_FILE="$2"
      shift 2
      ;;
    --skip-zshrc)
      SKIP_ZSHRC=1
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *) die "unknown plan option $1" ;;
    esac
  done

  [ -n "${PLAN_DIR}" ] || die '--plan is required'
  case "${PROFILE}" in loader | annex | zunit) ;; *) die "unsupported profile ${PROFILE}" ;; esac
  if [ -z "${CONFIG_HOME}" ]; then
    if is_absolute_path "${XDG_CONFIG_HOME-}"; then
      CONFIG_HOME="${XDG_CONFIG_HOME}/zi"
    else
      CONFIG_HOME="${HOME}/.config/zi"
    fi
  fi
  is_absolute_path "${CONFIG_HOME}" || die '--config-home must be absolute'
  if [ -z "${ZSHRC_PATH}" ]; then
    PLAN_ZDOTDIR="${ZDOTDIR:-${HOME}}"
    is_absolute_path "${PLAN_ZDOTDIR}" || die 'ZDOTDIR must be absolute when set'
    ZSHRC_PATH="${PLAN_ZDOTDIR}/.zshrc"
  fi
  is_absolute_path "${ZSHRC_PATH}" || die '--zshrc must be absolute'
  validate_text_path '--config-home' "${CONFIG_HOME}"
  validate_text_path '--zshrc' "${ZSHRC_PATH}"

  LEGACY_DIRECT_FOUND=0
  LEGACY_DIRECT_HOME=""
  LEGACY_DIRECT_BIN=""
  LEGACY_DIRECT_REF=""
  if [ "${SKIP_ZSHRC}" -eq 0 ]; then
    extract_legacy_direct_values "${ZSHRC_PATH}"
  fi
  if [ "${LEGACY_DIRECT_FOUND}" -eq 1 ]; then
    [ "${PLAN_HOME_EXPLICIT}" -eq 1 ] || PLAN_ZI_HOME="${LEGACY_DIRECT_HOME}"
    [ "${PLAN_BIN_EXPLICIT}" -eq 1 ] || PLAN_BIN="${LEGACY_DIRECT_BIN}"
    [ "${REF_EXPLICIT}" -eq 1 ] || REF="${LEGACY_DIRECT_REF}"
  fi
  validate_ref "${REF}"
  [ -n "${PLAN_ZI_HOME}" ] || PLAN_ZI_HOME="$(resolve_zi_home)"
  is_absolute_path "${PLAN_ZI_HOME}" || die '--zi-home must be absolute'
  case "${PLAN_BIN}" in "" | . | .. | */*) die '--zi-bin-dir must be one directory name' ;; esac
  validate_text_path '--zi-home' "${PLAN_ZI_HOME}"
  validate_text_path '--zi-bin-dir' "${PLAN_BIN}"
  CHECKOUT_PATH="${PLAN_ZI_HOME}/${PLAN_BIN}"
  [ -r "${INIT_SOURCE}" ] || die "cannot read init asset ${INIT_SOURCE}"
  [ -r "${PROFILES_FILE}" ] || die "cannot read profile table ${PROFILES_FILE}"
  [ -r "${CHECKSUM_FILE}" ] || die "cannot read checksum file ${CHECKSUM_FILE}"

  EXPECTED_INIT="$(awk '$2 == "public/zsh/init.zsh" {print $1}' "${CHECKSUM_FILE}")"
  [ -n "${EXPECTED_INIT}" ] || die 'checksum file has no public/zsh/init.zsh entry'
  [ "$(sha256_file "${INIT_SOURCE}")" = "${EXPECTED_INIT}" ] || die 'init asset does not match the published checksum'
  [ ! -e "${PLAN_DIR}" ] || die "plan path already exists: ${PLAN_DIR}"

  PLAN_WORK="$(mktemp -d "${TMPDIR:-/tmp}/zi-setup-plan.XXXXXX")" || exit 1
  trap 'rm -rf "${PLAN_WORK:?}"' EXIT INT TERM
  command mkdir -p "${PLAN_WORK}/artifact/checkout" "${PLAN_WORK}/artifact/targets"
  : >"${PLAN_WORK}/artifact/targets/order"
  RECEIPT_PATH="${CONFIG_HOME}/setup/receipt"

  INIT_CONTENT="${PLAN_WORK}/init.zsh"
  # The single-quoted portions preserve the literal Zsh parameter text.
  # shellcheck disable=SC2016
  command sed 's|: "${ZI\[STREAM\]:=main}"|: "${ZI[STREAM]:='"${REF}"'}"|' "${INIT_SOURCE}" >"${INIT_CONTENT}"
  PRE_CONTENT="${PLAN_WORK}/pre.zsh"
  PLAN_ZI_HOME_TEXT="$(zsh_single_quote "${PLAN_ZI_HOME}")" || die 'failed to serialize the Zi home'
  CHECKOUT_PATH_TEXT="$(zsh_single_quote "${CHECKOUT_PATH}")" || die 'failed to serialize the checkout path'
  REF_TEXT="$(zsh_single_quote "${REF}")" || die 'failed to serialize the ref'
  {
    printf '%s\n' '# Generated by Zi guided setup. Edit choices through a new plan.'
    printf '%s\n' 'typeset -gA ZI'
    printf 'ZI[HOME_DIR]=%s\n' "${PLAN_ZI_HOME_TEXT}"
    printf 'ZI[BIN_DIR]=%s\n' "${CHECKOUT_PATH_TEXT}"
    printf 'ZI[STREAM]=%s\n' "${REF_TEXT}"
  } >"${PRE_CONTENT}"

  ENTRY_CONTENT="${PLAN_WORK}/setup.zsh"
  write_setup_entrypoint "${CONFIG_HOME}" >"${ENTRY_CONTENT}"
  MANAGED_BLOCK="${PLAN_WORK}/managed-block"
  write_managed_block "${CONFIG_HOME}" >"${MANAGED_BLOCK}"
  DIRECT_TEMPLATE="${PLAN_WORK}/legacy-direct"
  LOADER_TEMPLATE="${PLAN_WORK}/legacy-loader"
  LOADER_EXPLICIT_TEMPLATE="${PLAN_WORK}/legacy-loader-explicit"
  ANNEX_TEMPLATE="${PLAN_WORK}/legacy-annex"
  ZUNIT_TEMPLATE="${PLAN_WORK}/legacy-zunit"
  if [ "${LEGACY_DIRECT_FOUND}" -eq 1 ]; then
    write_legacy_direct "${LEGACY_DIRECT_HOME}" "${LEGACY_DIRECT_BIN}" "${LEGACY_DIRECT_REF}" >"${DIRECT_TEMPLATE}"
  else
    write_legacy_direct "${PLAN_ZI_HOME}" "${PLAN_BIN}" "${REF}" >"${DIRECT_TEMPLATE}"
  fi
  write_legacy_loader >"${LOADER_TEMPLATE}"
  write_legacy_loader_explicit "${PLAN_ZI_HOME}" "${PLAN_BIN}" >"${LOADER_EXPLICIT_TEMPLATE}"
  write_legacy_annex >"${ANNEX_TEMPLATE}"
  write_legacy_zunit >"${ZUNIT_TEMPLATE}"

  DIRECT_MIGRATED=0
  EFFECTIVE_PROFILE="${PROFILE}"
  ZSHRC_CONTENT="${PLAN_WORK}/zshrc"
  if [ "${SKIP_ZSHRC}" -eq 0 ]; then
    CURRENT_ZSHRC="${PLAN_WORK}/zshrc-current"
    if [ -e "${ZSHRC_PATH}" ]; then command cp "${ZSHRC_PATH}" "${CURRENT_ZSHRC}"; else : >"${CURRENT_ZSHRC}"; fi
    START_COUNT="$(grep -c '^# >>> zi setup >>>$' "${CURRENT_ZSHRC}" 2>/dev/null || true)"
    END_COUNT="$(grep -c '^# <<< zi setup <<<$' "${CURRENT_ZSHRC}" 2>/dev/null || true)"
    if [ "${START_COUNT}" -ne 0 ] || [ "${END_COUNT}" -ne 0 ]; then
      [ "${START_COUNT}" -eq 1 ] && [ "${END_COUNT}" -eq 1 ] || die 'managed .zshrc markers are ambiguous'
      CURRENT_BLOCK="${PLAN_WORK}/current-block"
      extract_managed_block "${CURRENT_ZSHRC}" "${CURRENT_BLOCK}"
      CURRENT_BLOCK_HASH="$(sha256_file "${CURRENT_BLOCK}")"
      RECEIPT_BLOCK_HASH="$(receipt_value zshrc.block "${RECEIPT_PATH}" 2>/dev/null || true)"
      if ! cmp -s "${CURRENT_BLOCK}" "${MANAGED_BLOCK}" && [ "${CURRENT_BLOCK_HASH}" != "${RECEIPT_BLOCK_HASH}" ]; then
        diff_target "${CURRENT_BLOCK}" "${MANAGED_BLOCK}" "${PLAN_WORK}/empty" >&2 || true
        die 'managed .zshrc block changed outside Zi setup; apply the printed patch manually or restore the receipt state'
      fi
      replace_managed_block "${CURRENT_ZSHRC}" "${MANAGED_BLOCK}" "${ZSHRC_CONTENT}"
    else
      WORKING_ZSHRC="${PLAN_WORK}/zshrc-working"
      command cp "${CURRENT_ZSHRC}" "${WORKING_ZSHRC}"
      for ENTRY in \
        "direct:${DIRECT_TEMPLATE}" \
        "loader:${LOADER_TEMPLATE}" \
        "loader-explicit:${LOADER_EXPLICIT_TEMPLATE}" \
        "annex:${ANNEX_TEMPLATE}" \
        "zunit:${ZUNIT_TEMPLATE}"; do
        ENTRY_NAME="${ENTRY%%:*}"
        ENTRY_TEMPLATE="${ENTRY#*:}"
        STRIPPED="${PLAN_WORK}/zshrc-stripped"
        STRIP_RESULT="${PLAN_WORK}/strip-result"
        strip_exact_block "${WORKING_ZSHRC}" "${ENTRY_TEMPLATE}" "${STRIPPED}" "${STRIP_RESULT}"
        MATCHES="$(cat "${STRIP_RESULT}")"
        [ "${MATCHES}" -le 1 ] || die "legacy ${ENTRY_NAME} block appears more than once"
        if [ "${MATCHES}" -eq 1 ]; then
          command mv "${STRIPPED}" "${WORKING_ZSHRC}"
          case "${ENTRY_NAME}" in
          direct) DIRECT_MIGRATED=1 ;;
          annex) [ "${EFFECTIVE_PROFILE}" = zunit ] || EFFECTIVE_PROFILE=annex ;;
          zunit) EFFECTIVE_PROFILE=zunit ;;
          esac
        fi
      done
      if grep -E '^[[:space:]]*(source|\.)[[:space:]]+[^#]*(zi|init|zinit)\.zsh(["'"'"'[:space:]]|$)' "${WORKING_ZSHRC}" >/dev/null 2>&1 ||
        grep -E '^[[:space:]]*command git clone .*github\.com/z-shell/zi([. ]|$)' "${WORKING_ZSHRC}" >/dev/null 2>&1 ||
        grep -E '^[^#]*z-shell/z-a-meta-plugins([[:space:]]|$)' "${WORKING_ZSHRC}" >/dev/null 2>&1; then
        die 'unrecognised Zi integration remains in .zshrc; refusing to initialise Zi twice'
      fi
      command cp "${WORKING_ZSHRC}" "${ZSHRC_CONTENT}"
      if [ -s "${ZSHRC_CONTENT}" ]; then printf '\n' >>"${ZSHRC_CONTENT}"; fi
      command cat "${MANAGED_BLOCK}" >>"${ZSHRC_CONTENT}"
    fi
  fi

  SHELL_CONTENT="${PLAN_WORK}/shell.zsh"
  write_shell_fragment "${EFFECTIVE_PROFILE}" "${DIRECT_MIGRATED}" "${PROFILES_FILE}" "${SHELL_CONTENT}"

  command cat >"${PLAN_WORK}/artifact/plan.meta" <<EOF
format=zi-setup-plan-v1
profile=${EFFECTIVE_PROFILE}
ref=${REF}
config_home=${CONFIG_HOME}
checkout_path=${CHECKOUT_PATH}
receipt_path=${RECEIPT_PATH}
skip_zshrc=${SKIP_ZSHRC}
EOF

  if [ -d "${CHECKOUT_PATH}/.git" ]; then
    CHECKOUT_ORIGIN="$(command git -C "${CHECKOUT_PATH}" remote get-url origin 2>/dev/null || true)"
    case "${CHECKOUT_ORIGIN}" in
    https://github.com/z-shell/zi | https://github.com/z-shell/zi.git | git@github.com:z-shell/zi | git@github.com:z-shell/zi.git) ;;
    *) die "${CHECKOUT_PATH} is not a z-shell/zi checkout" ;;
    esac
    [ -f "${CHECKOUT_PATH}/zi.zsh" ] || die "${CHECKOUT_PATH} has no zi.zsh"
    CHECKOUT_HEAD="$(command git -C "${CHECKOUT_PATH}" rev-parse HEAD)" || die 'cannot read checkout HEAD'
    CHECKOUT_BRANCH="$(command git -C "${CHECKOUT_PATH}" symbolic-ref --quiet --short HEAD)" || die 'detached Zi checkout requires manual remediation'
    printf '%s\n' existing >"${PLAN_WORK}/artifact/checkout/kind"
    printf '%s\n' "${CHECKOUT_HEAD}" >"${PLAN_WORK}/artifact/checkout/head"
    printf '%s\n' "${CHECKOUT_BRANCH}" >"${PLAN_WORK}/artifact/checkout/current-ref"
    printf '%s\n' "${CHECKOUT_ORIGIN}" >"${PLAN_WORK}/artifact/checkout/origin"
  elif [ -e "${CHECKOUT_PATH}" ]; then
    die "${CHECKOUT_PATH} exists but is not a Zi checkout"
  else
    printf '%s\n' missing >"${PLAN_WORK}/artifact/checkout/kind"
    printf '%s\n' missing >"${PLAN_WORK}/artifact/checkout/head"
    printf '%s\n' missing >"${PLAN_WORK}/artifact/checkout/current-ref"
    printf '%s\n' missing >"${PLAN_WORK}/artifact/checkout/origin"
  fi
  printf '%s\n' "${REF}" >"${PLAN_WORK}/artifact/checkout/requested-ref"

  add_target "${PLAN_WORK}/artifact" init "${CONFIG_HOME}/init.zsh" "${INIT_CONTENT}" 755 "${RECEIPT_PATH}"
  add_target "${PLAN_WORK}/artifact" pre "${CONFIG_HOME}/setup/pre.zsh" "${PRE_CONTENT}" 600 "${RECEIPT_PATH}"
  add_target "${PLAN_WORK}/artifact" shell "${CONFIG_HOME}/setup/shell.zsh" "${SHELL_CONTENT}" 600 "${RECEIPT_PATH}"
  add_target "${PLAN_WORK}/artifact" entry "${CONFIG_HOME}/setup.zsh" "${ENTRY_CONTENT}" 600 "${RECEIPT_PATH}"
  if [ "${SKIP_ZSHRC}" -eq 0 ]; then
    add_target "${PLAN_WORK}/artifact" zshrc "${ZSHRC_PATH}" "${ZSHRC_CONTENT}" preserve "${RECEIPT_PATH}"
    printf '%s\n' "$(sha256_file "${MANAGED_BLOCK}")" >"${PLAN_WORK}/artifact/targets/zshrc/block-hash"
  fi

  command mv "${PLAN_WORK}/artifact" "${PLAN_DIR}"
  PLAN_ID="$(artifact_hash "${PLAN_DIR}")"
  printf '%s\n' "${PLAN_ID}" >"${PLAN_DIR}/plan.id"
  printf '%s\n' "Plan SHA256: ${PLAN_ID}"
  printf '%s\n' "Checkout phase: $(cat "${PLAN_DIR}/checkout/kind") ${CHECKOUT_PATH} -> ${REF}"
  while IFS= read -r TARGET_ID; do
    TARGET_PATH="$(cat "${PLAN_DIR}/targets/${TARGET_ID}/path")"
    diff_target "${TARGET_PATH}" "${PLAN_DIR}/targets/${TARGET_ID}/content" "${PLAN_WORK}/empty" || true
  done <"${PLAN_DIR}/targets/order"
}

nearest_existing_parent() {
  _parent_path="$1"
  while [ ! -d "${_parent_path}" ]; do
    _parent_next="$(dirname "${_parent_path}")"
    [ "${_parent_next}" != "${_parent_path}" ] || break
    _parent_path="${_parent_next}"
  done
  printf '%s\n' "${_parent_path}"
}

acquire_lock() {
  _lock_path="$1"
  command mkdir -p "$(dirname "${_lock_path}")"
  if ! command mkdir "${_lock_path}" 2>/dev/null; then
    die "lock is already held: ${_lock_path}"
  fi
  ACTIVE_LOCK="${_lock_path}"
  trap 'rmdir "${ACTIVE_LOCK}" 2>/dev/null || true' EXIT INT TERM
}

validate_plan() {
  _validate_plan="$1"
  _validate_expect="$2"
  [ -d "${_validate_plan}" ] || die "plan directory not found: ${_validate_plan}"
  [ "$(plan_value format "${_validate_plan}")" = zi-setup-plan-v1 ] || die 'unsupported plan format'
  _validate_stored="$(cat "${_validate_plan}/plan.id" 2>/dev/null || true)"
  _validate_actual="$(artifact_hash "${_validate_plan}")"
  [ "${_validate_stored}" = "${_validate_actual}" ] || die 'plan artifact hash mismatch'
  if [ -n "${_validate_expect}" ]; then
    [ "${_validate_expect}" = "${_validate_actual}" ] || die 'plan does not match --expect'
  fi
  printf '%s\n' "${_validate_actual}"
}

apply_checkout() {
  _checkout_plan="$1"
  _checkout_path="$(plan_value checkout_path "${_checkout_plan}")"
  _checkout_ref="$(cat "${_checkout_plan}/checkout/requested-ref")"
  _checkout_kind="$(cat "${_checkout_plan}/checkout/kind")"
  _checkout_head="$(cat "${_checkout_plan}/checkout/head")"
  _checkout_current_ref="$(cat "${_checkout_plan}/checkout/current-ref")"
  _checkout_origin="$(cat "${_checkout_plan}/checkout/origin")"
  _checkout_parent="$(dirname "${_checkout_path}")"
  _checkout_existing_parent="$(nearest_existing_parent "${_checkout_parent}")"
  [ -w "${_checkout_existing_parent}" ] || die "checkout parent is not writable: ${_checkout_existing_parent}"
  acquire_lock "${_checkout_path}.zi-setup.lock"

  case "${_checkout_kind}" in
  missing)
    [ ! -e "${_checkout_path}" ] || die "checkout appeared after planning: ${_checkout_path}"
    command mkdir -p "${_checkout_parent}"
    _checkout_tmp="${_checkout_path}.zi-setup-new.$$"
    [ ! -e "${_checkout_tmp}" ] || die "temporary checkout path exists: ${_checkout_tmp}"
    if ! command git clone --depth=1 --single-branch --branch "${_checkout_ref}" https://github.com/z-shell/zi.git "${_checkout_tmp}"; then
      command rm -rf "${_checkout_tmp}"
      die "failed to clone Zi at ${_checkout_ref}"
    fi
    command mv "${_checkout_tmp}" "${_checkout_path}"
    ;;
  existing)
    [ -d "${_checkout_path}/.git" ] || die 'checkout disappeared after planning'
    [ "$(command git -C "${_checkout_path}" rev-parse HEAD)" = "${_checkout_head}" ] || die 'checkout HEAD changed after planning'
    [ "$(command git -C "${_checkout_path}" symbolic-ref --quiet --short HEAD)" = "${_checkout_current_ref}" ] || die 'checkout ref changed after planning'
    [ "$(command git -C "${_checkout_path}" remote get-url origin 2>/dev/null || true)" = "${_checkout_origin}" ] || die 'checkout origin changed after planning'
    [ -f "${_checkout_path}/zi.zsh" ] || die 'checkout zi.zsh disappeared after planning'
    command git -C "${_checkout_path}" fetch origin "refs/heads/${_checkout_ref}" || die 'checkout fetch failed'
    command git -C "${_checkout_path}" merge --ff-only FETCH_HEAD || {
      command git -C "${_checkout_path}" status --short --branch >&2 || true
      die 'checkout cannot be fast-forwarded; local state was left untouched'
    }
    ;;
  *) die "invalid checkout kind ${_checkout_kind}" ;;
  esac
  printf '%s\n' "Checkout phase applied: ${_checkout_path}"
}

validate_target_precondition() {
  _validate_target_plan="$1"
  _validate_target_id="$2"
  _validate_target_dir="${_validate_target_plan}/targets/${_validate_target_id}"
  _validate_target_path="$(cat "${_validate_target_dir}/path")"
  _validate_target_kind="$(cat "${_validate_target_dir}/kind")"
  _validate_target_expected="$(cat "${_validate_target_dir}/expected")"
  if [ "${_validate_target_kind}" = symlink ] || [ -L "${_validate_target_path}" ]; then
    if [ "${_validate_target_id}" = zshrc ]; then
      diff_target "${_validate_target_path}" "${_validate_target_dir}/content" "${_validate_target_plan}/targets/.empty" >&2 || true
    fi
    die "refusing symlink target ${_validate_target_path}; apply the printed patch to its target manually"
  fi
  _validate_target_actual="$(current_hash "${_validate_target_path}")"
  [ "${_validate_target_actual}" = "${_validate_target_expected}" ] ||
    die "target changed after planning: ${_validate_target_path}"
  _validate_target_parent="$(nearest_existing_parent "$(dirname "${_validate_target_path}")")"
  [ -w "${_validate_target_parent}" ] || die "target parent is not writable: ${_validate_target_parent}"
}

install_target() {
  _install_plan="$1"
  _install_id="$2"
  _install_dir="${_install_plan}/targets/${_install_id}"
  _install_path="$(cat "${_install_dir}/path")"
  _install_mode="$(cat "${_install_dir}/mode")"
  _install_parent="$(dirname "${_install_path}")"
  command mkdir -p "${_install_parent}"
  _install_tmp="$(mktemp "${_install_path}.zi-setup.XXXXXX")" || die "cannot stage ${_install_path}"
  if [ -e "${_install_path}" ]; then
    command cp -p "${_install_path}" "${_install_tmp}"
  fi
  command cp "${_install_dir}/content" "${_install_tmp}"
  case "${_install_mode}" in
  755) command chmod 755 "${_install_tmp}" ;;
  600) command chmod 600 "${_install_tmp}" ;;
  preserve) [ -e "${_install_path}" ] || command chmod 600 "${_install_tmp}" ;;
  *)
    command rm -f "${_install_tmp}"
    die "invalid target mode ${_install_mode}"
    ;;
  esac
  command mv "${_install_tmp}" "${_install_path}"
}

apply_files() {
  _files_plan="$1"
  _files_plan_id="$2"
  _files_config="$(plan_value config_home "${_files_plan}")"
  _files_receipt="$(plan_value receipt_path "${_files_plan}")"
  _files_config_parent="$(nearest_existing_parent "$(dirname "${_files_config}")")"
  [ -w "${_files_config_parent}" ] || die "configuration parent is not writable: ${_files_config_parent}"
  acquire_lock "${_files_config}.zi-setup.lock"

  while IFS= read -r _files_id; do
    validate_target_precondition "${_files_plan}" "${_files_id}"
  done <"${_files_plan}/targets/order"

  while IFS= read -r _files_id; do
    install_target "${_files_plan}" "${_files_id}"
  done <"${_files_plan}/targets/order"

  command mkdir -p "$(dirname "${_files_receipt}")"
  _files_receipt_tmp="$(mktemp "${_files_receipt}.zi-setup.XXXXXX")" || die 'cannot stage receipt'
  {
    printf '%s\n' 'format=zi-setup-receipt-v1'
    printf 'plan=%s\n' "${_files_plan_id}"
    printf 'profile=%s\n' "$(plan_value profile "${_files_plan}")"
    while IFS= read -r _files_id; do
      _files_path="$(cat "${_files_plan}/targets/${_files_id}/path")"
      printf 'target.%s=%s\n' "${_files_id}" "$(sha256_file "${_files_path}")"
    done <"${_files_plan}/targets/order"
    if [ -f "${_files_plan}/targets/zshrc/block-hash" ]; then
      printf 'zshrc.block=%s\n' "$(cat "${_files_plan}/targets/zshrc/block-hash")"
    fi
    case "$(plan_value profile "${_files_plan}")" in
    annex | zunit) printf '%s\n' 'deferred-recipes=first-shell-start' ;;
    *) printf '%s\n' 'deferred-recipes=none' ;;
    esac
  } >"${_files_receipt_tmp}"
  command chmod 600 "${_files_receipt_tmp}"
  command mv "${_files_receipt_tmp}" "${_files_receipt}"
  printf '%s\n' "Files phase applied. Receipt: ${_files_receipt}"
}

apply_command() {
  APPLY_PLAN=""
  APPLY_PHASE=""
  APPLY_EXPECT=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --plan)
      [ "$#" -ge 2 ] || die '--plan requires a directory'
      APPLY_PLAN="$2"
      shift 2
      ;;
    --phase)
      [ "$#" -ge 2 ] || die '--phase requires checkout or files'
      APPLY_PHASE="$2"
      shift 2
      ;;
    --expect)
      [ "$#" -ge 2 ] || die '--expect requires a hash'
      APPLY_EXPECT="$2"
      shift 2
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *) die "unknown apply option $1" ;;
    esac
  done
  [ -n "${APPLY_PLAN}" ] || die '--plan is required'
  case "${APPLY_PHASE}" in checkout | files) ;; *) die '--phase must be checkout or files' ;; esac
  APPLY_PLAN_ID="$(validate_plan "${APPLY_PLAN}" "${APPLY_EXPECT}")"
  case "${APPLY_PHASE}" in
  checkout) apply_checkout "${APPLY_PLAN}" ;;
  files) apply_files "${APPLY_PLAN}" "${APPLY_PLAN_ID}" ;;
  esac
}

[ "$#" -gt 0 ] || {
  usage >&2
  exit 2
}
COMMAND="$1"
shift
case "${COMMAND}" in
plan) plan_command "$@" ;;
apply) apply_command "$@" ;;
--help | -h | help) usage ;;
*)
  usage >&2
  die "unknown command ${COMMAND}"
  ;;
esac
