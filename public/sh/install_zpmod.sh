#!/usr/bin/env sh
# -*- mode: sh; sh-indentation: 2; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: ft=sh sw=2 ts=2 et

set -eu

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/zi-zpmod.XXXXXX")" || exit 1
trap 'rm -rf "${WORKDIR:?}"' EXIT INT TERM

# Returns 0 if version $1 >= version $2 (dot-separated integers)
_zi_ver_ge() {
  _vga="$1" _vgb="$2"
  while [ -n "${_vga}${_vgb}" ]; do
    _af="${_vga%%.*}" _bf="${_vgb%%.*}"
    case "${_vga}" in *.*) _vga="${_vga#*.}" ;; *) _vga="" ;; esac
    case "${_vgb}" in *.*) _vgb="${_vgb#*.}" ;; *) _vgb="" ;; esac
    _af="${_af:-0}" _bf="${_bf:-0}"
    if [ "${_af}" -gt "${_bf}" ]; then return 0; fi
    if [ "${_af}" -lt "${_bf}" ]; then return 1; fi
  done
  return 0
}

setup_environment() {
  if [ -z "${ZI_HOME-}" ]; then
    _xdg_zi="${XDG_DATA_HOME:-${HOME}/.local/share}/zi"
    if [ -d "${_xdg_zi}" ]; then
      ZI_HOME="${_xdg_zi}"
    elif [ -d "${HOME}/.zi" ]; then
      ZI_HOME="${HOME}/.zi"
    elif [ -n "${ZDOTDIR-}" ] && [ -d "${ZDOTDIR}/.zi" ]; then
      ZI_HOME="${ZDOTDIR}/.zi"
    else
      ZI_HOME="${_xdg_zi}"
    fi
  fi
  if [ -z "${MOD_HOME-}" ]; then
    MOD_HOME="${ZI_HOME}/zmodules/zpmod"
  fi
  if ! test -d "${MOD_HOME}"; then
    mkdir -p "${MOD_HOME}"
    chmod go-w "${MOD_HOME}"
  fi
  if [ ! -d "${MOD_HOME}" ]; then
    printf '%s\n' "${col_error}== Error: Failed to setup module directory ==${col_rst}"
    exit 1
  fi
}

setup_zpmod_repository() {
  printf '%s\n' "${col_pname}== Downloading ZPMOD module to ${MOD_HOME}"
  if test -d "${MOD_HOME}/.git"; then
    cd "${MOD_HOME}" || exit 1
    git pull -q origin main
  else
    git clone --depth 10 -q https://github.com/z-shell/zpmod.git "${MOD_HOME}"
  fi
}

build_zpmod_module() {
  if command -v zsh >/dev/null; then
    printf '%s\n' "${col_info2}-- Checking version --${col_rst}"
    ZSH_CURRENT=$(zsh --version </dev/null | head -n1 | cut -d" " -f2,6- | tr -d '-')
    ZSH_REQUIRED="5.8.1"
    # shellcheck disable=SC2310
    if ! _zi_ver_ge "${ZSH_CURRENT}" "${ZSH_REQUIRED}"; then
      printf '%s\n' "${col_error}-- Zsh version ${ZSH_REQUIRED} and above required --${col_rst}"
      exit 1
    else
      (
        printf '%s\n' "${col_info2}-- Zsh version ${ZSH_CURRENT} --${col_rst}"
        cd "${MOD_HOME}" || exit 1
        printf '%s\n' "${col_pname}== Building module ZPMOD, running: a make clean, then ./configure and then make ==${col_rst}"
        printf '%s\n' "${col_pname}== The module sources are located at: ${MOD_HOME} ==${col_rst}"
        if test -f Makefile; then
          if [ "${1-}" = "--clean" ]; then
            printf '%s\n' "${col_info2}-- make distclean --${col_rst}"
            make distclean
            true
          else
            printf '%s\n' "${col_info2}-- make clean (pass --clean to invoke \`make distclean') --${col_rst}"
            make clean
          fi
        fi

        INSTALL_PATH="/usr/local"
        export PATH="${INSTALL_PATH}"/bin:"${PATH}"
        export LD_LIBRARY_PATH="${INSTALL_PATH}/lib:${LD_LIBRARY_PATH-}"
        export CFLAGS="-I${INSTALL_PATH}/include"
        export CPPFLAGS="-I${INSTALL_PATH}/include"
        export LDFLAGS="-L${INSTALL_PATH}/lib"
        CFLAGS="-g -Wall -O3" ./configure --disable-gdbm --without-tcsetpgrp --quiet

        printf '%s\n' "${col_info2}-- Running make --${col_rst}"
        if make -j 4 >/dev/null && [ -f Src/zi/zpmod.so ]; then
          cp -vf Src/zi/zpmod.so Src/zi/zpmod.bundle
          command cat <<-EOF
[38;5;219m▓▒░[0m [38;5;220mModule [38;5;177mhas been built correctly.
[38;5;219m▓▒░[0m [38;5;220mTo [38;5;160mload the module, add following [38;5;220m2 lines to [38;5;172m.zshrc, at top:

[0m [38;5;51m module_path+=( "${MOD_HOME}/Src" )
[0m [38;5;51m zmodload zi/zpmod

[38;5;219m▓▒░[0m [38;5;220mSee 'zpmod -h' for more information.
[38;5;219m▓▒░[0m [38;5;220mRun 'zpmod source-study' to see profile data,
[38;5;219m▓▒░[0m [38;5;177mGuaranteed, automatic compilation of any sourced script.
EOF
        else
          printf '%s\n' "${col_error}Module didn't build.${col_rst}. You can copy the error messages and submit"
          printf '%s\n' "error-report at: https://github.com/z-shell/zpmod/issues"
          exit 1
        fi
      )
    fi
  else
    printf '%s\n' "${col_error} Zsh is not installed. Please install zsh and try again.${col_rst}"
    exit 1
  fi
}

MAIN() {
  col_pname="[33m"
  col_error="[31m"
  col_info2="[32m"
  col_rst="[0m"

  if [ "$#" -gt 0 ]; then
    setup_environment "$@"
    setup_zpmod_repository "$@"
    build_zpmod_module "$@"
  else
    setup_environment
    setup_zpmod_repository
    build_zpmod_module
  fi
  exit 0
}

if [ "$#" -gt 0 ]; then
  MAIN "$@"
else
  MAIN
fi
