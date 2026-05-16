#!/usr/bin/env sh
# add-project-workflow.sh — Add project-tracker workflow to all org repos.
#
# Usage:
#   ./add-project-workflow.sh [owner] [repos-file]
#
# Defaults:
#   owner      = z-shell
#   repos-file = scripts/repos.txt
#
# Requirements:
#   - gh CLI authenticated with repo scope
#   - SSH key configured for git push
#   - z-shell/.github already has add-to-project.yml deployed

set -e

OWNER="${1:-z-shell}"
REPOS="${2:-$(dirname "$0")/repos.txt}"
WORKFLOW_FILE=".github/workflows/project-tracker.yml"
BRANCH="ci/add-project-tracker"

if [ ! -f "${REPOS}" ]; then
  printf 'Error: repos file not found: %s\n' "${REPOS}" >&2
  exit 1
fi

# Skip repos that already have the workflow or are the .github meta-repo
SKIP_REPOS=".github"

WORKFLOW_CONTENT='# Add issues and PRs to the Z-Shell Tracker project automatically.
name: Track in Z-Shell Tracker

on:
  issues:
    types: [opened, reopened, transferred]
  pull_request:
    types: [opened, reopened]

jobs:
  track:
    uses: z-shell/.github/.github/workflows/add-to-project.yml@main
    secrets: inherit
'

total=0
ok=0
skipped=0
failed=0

add_workflow() {
  repo="$1"
  printf '=== %s/%s ===\n' "${OWNER}" "${repo}"

  # Skip the .github meta-repo itself
  for skip in ${SKIP_REPOS}; do
    if [ "${repo}" = "${skip}" ]; then
      printf 'Skipping meta-repo\n'
      skipped=$((skipped + 1))
      return 0
    fi
  done

  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT INT TERM

  # Clone (shallow) — skip archived/empty repos gracefully
  if ! git clone --depth=1 "git@github.com:${OWNER}/${repo}.git" "${tmpdir}/${repo}" 2>/dev/null; then
    printf 'SKIP: cannot clone (archived or empty?)\n'
    skipped=$((skipped + 1))
    trap - EXIT INT TERM
    rm -rf "${tmpdir}"
    return 0
  fi

  cd "${tmpdir}/${repo}"

  # Skip if workflow already exists
  if [ -f "${WORKFLOW_FILE}" ]; then
    printf 'SKIP: workflow already present\n'
    skipped=$((skipped + 1))
    cd - >/dev/null
    trap - EXIT INT TERM
    rm -rf "${tmpdir}"
    return 0
  fi

  # Get default branch
  default_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")

  git checkout -b "${BRANCH}" 2>/dev/null || git checkout "${BRANCH}"
  mkdir -p "$(dirname "${WORKFLOW_FILE}")"
  printf '%s' "${WORKFLOW_CONTENT}" >"${WORKFLOW_FILE}"

  git add "${WORKFLOW_FILE}"
  git commit -m "ci: add project tracker workflow"
  git push origin "${BRANCH}"

  # Open a PR
  # shellcheck disable=SC2016
  gh pr create \
    --repo "${OWNER}/${repo}" \
    --base "${default_branch}" \
    --head "${BRANCH}" \
    --title "ci: add project tracker workflow" \
    --body 'Adds the `.github/workflows/project-tracker.yml` workflow so new issues and PRs are automatically added to the [Z-Shell Tracker](https://github.com/orgs/z-shell/projects/28) project.

Uses the shared reusable workflow from `z-shell/.github` — no per-repo secrets needed.' \
    2>/dev/null && printf 'PR opened\n' || printf 'PR already open or failed\n'

  ok=$((ok + 1))
  cd - >/dev/null
  trap - EXIT INT TERM
  rm -rf "${tmpdir}"
}

while IFS= read -r repo || [ -n "${repo}" ]; do
  [ -z "${repo}" ] && continue
  total=$((total + 1))
  # shellcheck disable=SC2310
  add_workflow "${repo}" || {
    failed=$((failed + 1))
    printf 'FAILED: %s/%s\n' "${OWNER}" "${repo}" >&2
  }
done <"${REPOS}"

printf '\nDone — %d total, %d ok, %d skipped, %d failed\n' \
  "${total}" "${ok}" "${skipped}" "${failed}"
