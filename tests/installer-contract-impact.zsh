#!/usr/bin/env zsh
# -*- mode: zsh; sh-indentation: 2; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: ft=zsh sw=2 ts=2 et

emulate -LR zsh
setopt err_exit no_unset pipe_fail extended_glob

typeset project_root="${0:A:h:h}"
typeset temp_root
temp_root="$(command mktemp -d "${TMPDIR:-/tmp}/src-contract-test.XXXXXXXX")"
trap 'command rm -rf -- "$temp_root"' EXIT INT TERM

fail() {
  print -u2 "not ok - $1"
  exit 1
}

assert_contains() {
  local output="$1" expected="$2"
  [[ $output == *"$expected"* ]] || fail "expected output to contain: $expected\n--- Output was:\n$output"
}

assert_not_contains() {
  local output="$1" unexpected="$2"
  [[ $output != *"$unexpected"* ]] || fail "expected output not to contain: $unexpected\n--- Output was:\n$output"
}

new_case_repository() {
  local name="$1"
  local repository="${temp_root}/${name}"
  command mkdir -p "$repository/contracts" "$repository/public/sh" "$repository/public/setup" "$repository/docs" "$repository/.github/skills/zi-install"
  command cp "$project_root/contracts/installer-contract-v1.json" "$repository/contracts/"
  command cp "$project_root/public/sh/install.sh" "$repository/public/sh/"
  command cp "$project_root/public/sh/setup.sh" "$repository/public/sh/"
  command cp "$project_root/public/setup/profiles.tsv" "$repository/public/setup/"
  command cp "$project_root/public/checksum.txt" "$repository/public/"
  command cp "$project_root/public/index.html" "$repository/public/"
  command cp "$project_root/docs/README.md" "$repository/docs/"
  command cp "$project_root/.github/skills/zi-install/SKILL.md" "$repository/.github/skills/zi-install/"
  command git -C "$repository" init -q
  command git -C "$repository" config user.name "Contract Test"
  command git -C "$repository" config user.email "contract-test@example.invalid"
  command git -C "$repository" add .
  command git -C "$repository" commit -qm "test: base installer contract"
  command git -C "$repository" tag base
  print -r -- "$repository"
}

run_detector() {
  local repository="$1"
  shift
  zsh "$project_root/scripts/installer-contract-impact.zsh" \
    --repository "$repository" \
    --base base \
    --head HEAD \
    "$@"
}

typeset repository output

# 1. Bootstrap: base has no manifest or contract
repository="${temp_root}/bootstrap"
command mkdir -p "$repository/public/sh" "$repository/docs"
print "echo legacy" > "$repository/public/sh/install.sh"
command git -C "$repository" init -q
command git -C "$repository" config user.name "Contract Test"
command git -C "$repository" config user.email "contract-test@example.invalid"
command git -C "$repository" add .
command git -C "$repository" commit -qm "test: initial base without contract"
command git -C "$repository" tag base

# Now head introduces the manifest and installer files
command mkdir -p "$repository/contracts" "$repository/public/setup" "$repository/.github/skills/zi-install"
command cp "$project_root/contracts/installer-contract-v1.json" "$repository/contracts/"
command cp "$project_root/public/sh/setup.sh" "$repository/public/sh/"
command cp "$project_root/public/setup/profiles.tsv" "$repository/public/setup/"
command cp "$project_root/public/checksum.txt" "$repository/public/"
command cp "$project_root/public/index.html" "$repository/public/"
command cp "$project_root/docs/README.md" "$repository/docs/"
command cp "$project_root/.github/skills/zi-install/SKILL.md" "$repository/.github/skills/zi-install/"
command git -C "$repository" add .
command git -C "$repository" commit -qm "feat: introduce installer contract v1"

output="$(run_detector "$repository" --no-policy)"
assert_contains "$output" "Installer contract bootstrap"
assert_contains "$output" "Introducing contract version v1"
print "ok 1 - bootstrap mode safely succeeds when base has no trusted detector"

# 2. No impact: changes to unrelated files
repository="$(new_case_repository no-impact)"
print "# Documentation note" >> "$repository/docs/README.md"
# Note: docs/README.md is a consumer, not a declared installer source path!
command git -C "$repository" add .
command git -C "$repository" commit -qm "docs: add note"
output="$(run_detector "$repository")"
assert_contains "$output" "No installer contract changes detected."
print "ok 2 - changes to non-source paths detect no impact"

# 3. Relevant source change without version bump
repository="$(new_case_repository source-change-no-bump)"
print "# modification" >> "$repository/public/sh/setup.sh"
command git -C "$repository" add .
command git -C "$repository" commit -qm "fix: modify setup.sh without version bump"
if output="$(run_detector "$repository" 2>&1)"; then
  fail "source change without version bump unexpectedly passed policy"
fi
assert_contains "$output" "Contract-version bump required"
print "ok 3 - source changes without contract-version bump fail policy"

# 4. Version bump without acknowledgement
repository="$(new_case_repository bump-without-ack)"
print "# modification" >> "$repository/public/sh/setup.sh"
typeset changed_manifest="${repository}/contracts/installer-contract-v1.json.new"
jq '.contract_version = 2' "$repository/contracts/installer-contract-v1.json" > "$changed_manifest"
command mv "$changed_manifest" "$repository/contracts/installer-contract-v1.json"
command git -C "$repository" add .
command git -C "$repository" commit -qm "feat!: modify setup.sh with version bump"
if output="$(PR_BODY="" run_detector "$repository" 2>&1)"; then
  fail "version bump without acknowledgement unexpectedly passed policy"
fi
assert_contains "$output" "Consumer-impact acknowledgement required"
assert_contains "$output" "[installer-impact:"
print "ok 4 - version bump without PR-body acknowledgement fails policy"

# 5. Accepted acknowledgement still requires refreshed consumer evidence
typeset -a impact_surfaces
impact_surfaces=( "${(@f)$(print -r -- "$output" | command grep -o '\[installer-impact:[^]]*\]' | LC_ALL=C sort -u)}" )
typeset pr_body="This PR updates installer setup behavior."
typeset marker
for marker in "${impact_surfaces[@]}"; do
  pr_body+=$'\n'"${marker} updated here"
done

if output="$(PR_BODY="$pr_body" run_detector "$repository" 2>&1)"; then
  fail "acknowledgement without refreshed consumers unexpectedly passed policy"
fi
assert_contains "$output" "Internal consumer refresh required"
assert_contains "$output" "External consumer evidence refresh required"

print "# contract review v2" >> "$repository/.github/skills/zi-install/SKILL.md"
print "<!-- contract review v2 -->" >> "$repository/docs/README.md"
print "<!-- contract review v2 -->" >> "$repository/public/index.html"
changed_manifest="${repository}/contracts/installer-contract-v1.json.new"
jq '
  .consumers |= map(
    if .scope == "external" then
      .evidence_status = "published"
      | .evidence = (
          "https://github.com/" + .repository
          + "/blob/2222222222222222222222222222222222222222/" + .path
        )
    else . end
  )
' "$repository/contracts/installer-contract-v1.json" > "$changed_manifest"
command mv "$changed_manifest" "$repository/contracts/installer-contract-v1.json"
command git -C "$repository" add .
command git -C "$repository" commit -qm "docs: refresh installer contract consumers"

output="$(PR_BODY="$pr_body" run_detector "$repository")"
assert_contains "$output" "Public installer contract impact"
assert_contains "$output" "Impacts"
assert_contains "$output" "Affected consumers"
print "ok 5 - version bump, acknowledgement, and refreshed consumers succeed"

# 6. Strict manifest validation failures
typeset -a validation_cases=(
  "schema_version" '.schema_version = 2'
  "contract_version" '.contract_version = "v1"'
  "surface_paths" 'del(.surfaces[0].paths)'
  "surface_unsafe_id" '.surfaces[0].id = "invalid/id"'
  "surface_duplicate_id" '.surfaces += [.surfaces[0]]'
  "consumer_unknown_surface" '.consumers[0].surfaces = ["nonexistent-surface"]'
  "unused_surface" '.surfaces += [{"id":"unused-surface","description":"unused","paths":["public/sh/install.sh"]}]'
  "consumer_unsafe_path" '.consumers[0].path = "/etc/passwd"'
  "consumer_invalid_repo" '.consumers[0].repository = "external-org/repo"'
  "consumer_invalid_evidence" '.consumers[0].evidence_status = "published" | .consumers[0].evidence = "https://github.com/z-shell/wiki/blob/main/docs/getting_started/01_installation.mdx"'
  "consumer_mismatched_evidence" '.consumers[0].evidence_status = "published" | .consumers[0].evidence = "https://github.com/z-shell/wiki/blob/0123456789abcdef0123456789abcdef01234567/other/path.md"'
)

integer i
for (( i = 1; i <= ${#validation_cases}; i += 2 )); do
  typeset case_name="${validation_cases[i]}"
  typeset jq_filter="${validation_cases[i+1]}"
  repository="$(new_case_repository "malformed-${case_name}")"
  changed_manifest="${repository}/contracts/installer-contract-v1.json.new"
  jq "$jq_filter" "$repository/contracts/installer-contract-v1.json" > "$changed_manifest"
  command mv "$changed_manifest" "$repository/contracts/installer-contract-v1.json"
  command git -C "$repository" add .
  command git -C "$repository" commit -qm "test: malformed manifest ${case_name}"
  if output="$(run_detector "$repository" --no-policy 2>&1)"; then
    fail "malformed manifest ${case_name} unexpectedly passed validation"
  fi
  assert_contains "$output" "invalid head manifest"
done
print "ok 6 - strict manifest validation rejects malformed surfaces, consumers, and evidence"

# 7. Pending external evidence semantics
# 7a: a manifest with pending external evidence verifies cleanly offline
typeset pending_manifest="${temp_root}/pending-manifest.json"
jq '
  .consumers |= map(
    if .scope == "external" then
      .evidence_status = "pending"
      | .evidence = null
    else . end
  )
' "$project_root/contracts/installer-contract-v1.json" > "$pending_manifest"
output="$(zsh "$project_root/scripts/installer-contract-evidence.zsh" --manifest "$pending_manifest")"
assert_contains "$output" "pending   z-shell/wiki/docs/getting_started/01_installation.mdx (pending publication)"
assert_contains "$output" "pending   z-shell/.github/.github/skills/zi-install/SKILL.md (pending publication)"
assert_contains "$output" "pending   z-shell/zi/README.md (pending publication)"
assert_contains "$output" "0 consumer pins current, 3 pending publication"
assert_not_contains "$output" "3 consumer pins current"

# 7b: evidence script rejects unresolvable / stale pins when present
typeset mock_bin="${temp_root}/mock-bin"
command mkdir -p "$mock_bin"
command cat > "$mock_bin/gh" <<'EOF'
#!/usr/bin/env sh
# Mock gh returning empty SHA to simulate unresolvable pin
echo ""
EOF
command chmod +x "$mock_bin/gh"

typeset stale_manifest="${temp_root}/stale-manifest.json"
jq '
  .consumers[0].evidence_status = "published"
  | .consumers[0].evidence = "https://github.com/z-shell/wiki/blob/1111111111111111111111111111111111111111/docs/getting_started/01_installation.mdx"
' "$pending_manifest" > "$stale_manifest"

if output="$(PATH="$mock_bin:$PATH" zsh "$project_root/scripts/installer-contract-evidence.zsh" --manifest "$stale_manifest" 2>&1)"; then
  fail "unresolvable evidence pin unexpectedly passed evidence verification"
fi
assert_contains "$output" "Unresolvable evidence"

command cat > "$mock_bin/gh" <<'EOF'
#!/usr/bin/env sh
# Mock gh returning different SHA for head vs pinned to simulate stale pin
case "$*" in
  *ref=1111111111111111111111111111111111111111*) echo "blob-pinned-sha-1111" ;;
  *) echo "blob-head-sha-2222" ;;
esac
EOF
command chmod +x "$mock_bin/gh"

if output="$(PATH="$mock_bin:$PATH" zsh "$project_root/scripts/installer-contract-evidence.zsh" --manifest "$stale_manifest" 2>&1)"; then
  fail "stale evidence pin unexpectedly passed evidence verification"
fi
assert_contains "$output" "Stale evidence pins"
print "ok 7 - pending external evidence is cleanly reported and stale pins fail"

print "All tests passed successfully."
