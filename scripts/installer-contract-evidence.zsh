#!/usr/bin/env zsh
# -*- mode: zsh; sh-indentation: 2; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: ft=zsh sw=2 ts=2 et
#
# installer-contract-evidence.zsh -- report stale consumer evidence pins.
#
# Every external entry in contracts/installer-contract-v1.json with published
# evidence cites a consumer file at a fixed commit. This script compares the
# Git blob object of each pinned path against the blob currently on the
# consumer repository default branch.
#
# Pending evidence entries (awaiting coordinated external publication) are
# clearly reported as pending without being claimed as current.
#
# Exit codes:
#   0  all external pins are current (or pending), internal files present
#   1  at least one pin is stale or unresolvable
#   2  usage or dependency error

emulate -LR zsh
setopt errexit nounset pipefail

typeset manifest_path="contracts/installer-contract-v1.json"
integer quiet=0

usage() {
  print "usage: ${0:t} [--manifest PATH] [--quiet]"
}

while (( $# )); do
  case "$1" in
    --manifest)
      manifest_path="${2-}"
      shift 2
      ;;
    --quiet)
      quiet=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      print -u2 "installer-contract-evidence: unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || {
  print -u2 "installer-contract-evidence: required command not found: jq"
  exit 2
}

[[ -r $manifest_path ]] || {
  print -u2 "installer-contract-evidence: cannot read manifest: ${manifest_path}"
  exit 2
}

# Check if any consumer has an external evidence pin that requires gh
integer has_external_pins=0
if jq -e '.consumers[] | select(.scope == "external" and .evidence_status == "published" and .evidence != null and .evidence != "")' "$manifest_path" >/dev/null 2>&1; then
  has_external_pins=1
fi

if (( has_external_pins )); then
  command -v gh >/dev/null 2>&1 || {
    print -u2 "installer-contract-evidence: required command not found: gh"
    exit 2
  }
fi

blob_at() {
  local repository="$1" file_path="$2" ref="${3-}" endpoint
  endpoint="repos/${repository}/contents/${file_path}"
  [[ -n $ref ]] && endpoint+="?ref=${ref}"
  command gh api "$endpoint" --jq '.sha' 2>/dev/null
}

typeset -a stale=() unresolved=() pending=() internal_verified=()
typeset line repository file_path scope evidence_status evidence commit pinned_blob head_blob
integer checked=0 pending_count=0 internal_count=0

while IFS=$'\t' read -r repository file_path scope evidence_status evidence; do
  [[ -n $repository ]] || continue

  if [[ $scope == "internal" ]]; then
    if [[ -f $file_path ]]; then
      (( internal_count += 1 ))
      internal_verified+=( "${repository}/${file_path}" )
      (( quiet )) || print -r -- "internal  ${repository}/${file_path}"
    else
      unresolved+=( "${repository}/${file_path} (missing internal file)" )
    fi
    continue
  fi

  # External consumer
  if [[ $evidence_status == "pending" || -z $evidence ]]; then
    (( pending_count += 1 ))
    pending+=( "${repository}/${file_path}" )
    (( quiet )) || print -r -- "pending   ${repository}/${file_path} (pending publication)"
    continue
  fi

  # Published/pinned external consumer
  commit="${${evidence#*/blob/}%%/*}"
  pinned_blob="$(blob_at "$repository" "$file_path" "$commit")" || pinned_blob=""
  head_blob="$(blob_at "$repository" "$file_path")" || head_blob=""

  if [[ -z $pinned_blob || -z $head_blob ]]; then
    unresolved+=( "${repository}/${file_path} (at commit ${commit})" )
    continue
  fi

  if [[ $pinned_blob != "$head_blob" ]]; then
    stale+=( "${repository}/${file_path}"$'\t'"${commit}"$'\t'"${pinned_blob}"$'\t'"${head_blob}" )
    continue
  fi

  (( checked += 1 ))
  (( quiet )) || print -r -- "current   ${repository}/${file_path}"
done < <(jq -r '.consumers[] | [.repository, .path, .scope, .evidence_status, (.evidence // "")] | @tsv' "$manifest_path")

if (( ${#unresolved} )); then
  print -u2 -r -- ""
  print -u2 -r -- "Unresolvable evidence (moved, renamed, missing, or private):"
  for line in "${unresolved[@]}"; do
    print -u2 -r -- "  ${line}"
  done
fi

if (( ${#stale} )); then
  print -u2 -r -- ""
  print -u2 -r -- "Stale evidence pins (consumer file changed since the pinned commit):"
  for line in "${stale[@]}"; do
    print -u2 -r -- "  ${${(s:	:)line}[1]}"
    print -u2 -r -- "    pinned commit : ${${(s:	:)line}[2]}"
    print -u2 -r -- "    pinned blob   : ${${(s:	:)line}[3]}"
    print -u2 -r -- "    current blob  : ${${(s:	:)line}[4]}"
  done
  print -u2 -r -- ""
  print -u2 -r -- "Re-read each consumer, confirm the claimed surfaces still apply,"
  print -u2 -r -- "then update its evidence commit and evidence_reviewed date."
fi

if (( ${#pending} )); then
  print -u2 -r -- ""
  print -u2 -r -- "Pending evidence (awaiting coordinated external publication):"
  for line in "${pending[@]}"; do
    print -u2 -r -- "  ${line}"
  done
fi

if (( ${#stale} || ${#unresolved} )); then
  exit 1
fi

(( quiet )) || print -r -- ""
print -r -- "installer-contract-evidence: ${checked} consumer pins current, ${pending_count} pending publication"

exit 0
