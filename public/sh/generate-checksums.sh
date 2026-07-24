#!/usr/bin/env sh
# -*- mode: sh; sh-indentation: 2; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: ft=sh sw=2 ts=2 et
#
# generate-checksums.sh — regenerate public/checksum.txt
#
# Usage (from any directory):
#   sh public/sh/generate-checksums.sh
#
# This script is also invoked by the CI workflows before running
# tests/installers.sh so that public/checksum.txt is always current.

set -eu

ROOT="$(
  unset CDPATH
  cd -- "$(dirname "$0")/../.." 2>/dev/null && pwd
)" || { printf '%s\n' "generate-checksums: cannot determine repository root" >&2; exit 1; }

CHECKSUM_FILE="${ROOT}/public/checksum.txt"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf '%s\n' "generate-checksums: sha256sum or shasum is required" >&2
    exit 1
  fi
}

# Clear (or create) the checksum file before writing fresh entries
> "${CHECKSUM_FILE}"
for f in \
  public/sh/install_zpmod.sh \
  public/sh/install.sh \
  public/sh/sync-init.sh \
  public/zsh/init.zsh
do
  hash="$(sha256_file "${ROOT}/${f}")"
  printf '%s %s\n' "${hash}" "${f}" >> "${CHECKSUM_FILE}"
done

printf '%s\n' "Checksums written to ${CHECKSUM_FILE}"
