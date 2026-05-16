#!/usr/bin/env sh
# sync-labels.sh — Apply canonical Z-Shell label set to org repos.
#
# Usage:
#   ./sync-labels.sh [owner] [repos-file]
#
# Defaults:
#   owner      = z-shell
#   repos-file = scripts/repos.txt  (one repo name per line)
#
# Requirements:
#   - gh CLI authenticated with repo scope
#   - gh label create supports --force (gh >= 2.14)

OWNER="${1:-z-shell}"
REPOS="${2:-$(dirname "$0")/repos.txt}"

if [ ! -f "${REPOS}" ]; then
  printf 'Error: repos file not found: %s\n' "${REPOS}" >&2
  exit 1
fi

apply_labels() {
  repo="$1"
  printf '=== %s/%s ===\n' "${OWNER}" "${repo}"

  # ── Type labels ──────────────────────────────────────────────────────────────
  gh label create "bug 🐛" --repo "${OWNER}/${repo}" --color d73a4a \
    --description "Something isn't working" --force
  gh label create "feature-request 💡" --repo "${OWNER}/${repo}" --color 0075ca \
    --description "New feature or request" --force
  gh label create "enhancement ✨" --repo "${OWNER}/${repo}" --color a2eeef \
    --description "Improvement to existing functionality" --force
  gh label create "documentation 📝" --repo "${OWNER}/${repo}" --color 0052cc \
    --description "Documentation-only changes" --force
  gh label create "performance 🚀" --repo "${OWNER}/${repo}" --color 006b75 \
    --description "Performance improvements" --force
  gh label create "security 🛡️" --repo "${OWNER}/${repo}" --color ee0701 \
    --description "Security vulnerability or hardening" --force
  gh label create "breaking-change 💥" --repo "${OWNER}/${repo}" --color d93f0b \
    --description "Breaks backward compatibility" --force
  gh label create "dependencies 📦" --repo "${OWNER}/${repo}" --color 0366d6 \
    --description "Dependency updates" --force
  gh label create "chore 🔧" --repo "${OWNER}/${repo}" --color c5def5 \
    --description "Routine maintenance, no behavior change" --force
  gh label create "refactor ♻️" --repo "${OWNER}/${repo}" --color 5319e7 \
    --description "Code refactor, no behavior change" --force
  gh label create "ci ⚙️" --repo "${OWNER}/${repo}" --color 1d76db \
    --description "CI/CD pipeline changes" --force

  # ── Status / workflow labels ─────────────────────────────────────────────────
  gh label create "triage 🔍" --repo "${OWNER}/${repo}" --color fbca04 \
    --description "Needs investigation before action" --force
  gh label create "in-progress 🚧" --repo "${OWNER}/${repo}" --color f9d0c4 \
    --description "Currently being worked on" --force
  gh label create "blocked ⛔" --repo "${OWNER}/${repo}" --color e4e669 \
    --description "Blocked on external dependency/decision" --force
  gh label create "stale 💤" --repo "${OWNER}/${repo}" --color f2f2f2 \
    --description "No activity for an extended period" --force
  gh label create "invalid ⚠️" --repo "${OWNER}/${repo}" --color e4e669 \
    --description "Off-topic, cannot reproduce, or incorrect" --force
  gh label create "wontfix 🚫" --repo "${OWNER}/${repo}" --color ffffff \
    --description "Will not be fixed" --force
  gh label create "no-stale 🔒" --repo "${OWNER}/${repo}" --color 0e8a16 \
    --description "Exempt from stale-bot closing" --force

  # ── Community labels ─────────────────────────────────────────────────────────
  gh label create "help-wanted 🙋" --repo "${OWNER}/${repo}" --color 008672 \
    --description "Extra attention or expertise needed" --force
  gh label create "good-first-issue 🌱" --repo "${OWNER}/${repo}" --color 7057ff \
    --description "Good for newcomers" --force
  gh label create "Q&A ✍️" --repo "${OWNER}/${repo}" --color d4c5f9 \
    --description "Questions and answers" --force
}

# ── Main loop ────────────────────────────────────────────────────────────────
total=0
ok=0
failed=0

while IFS= read -r repo || [ -n "${repo}" ]; do
  [ -z "${repo}" ] && continue
  total=$((total + 1))
  if apply_labels "${repo}"; then
    ok=$((ok + 1))
  else
    failed=$((failed + 1))
    printf 'FAILED: %s/%s\n' "${OWNER}" "${repo}" >&2
  fi
done <"${REPOS}"

printf '\nDone — %d total, %d ok, %d failed\n' "${total}" "${ok}" "${failed}"
