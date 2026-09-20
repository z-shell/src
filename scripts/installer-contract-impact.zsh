#!/usr/bin/env zsh
# -*- mode: zsh; sh-indentation: 2; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: ft=zsh sw=2 ts=2 et

emulate -LR zsh
setopt err_exit no_unset pipe_fail extended_glob

typeset repository="."
typeset manifest_path="contracts/installer-contract-v1.json"
typeset base_ref="" head_ref=""
integer enforce_policy=1

usage() {
  print "usage: ${0:t} --base REF --head REF [--repository DIR] [--manifest PATH] [--no-policy]"
}

while (( $# )); do
  case "$1" in
    --base)
      base_ref="${2-}"
      shift 2
      ;;
    --head)
      head_ref="${2-}"
      shift 2
      ;;
    --repository)
      repository="${2-}"
      shift 2
      ;;
    --manifest)
      manifest_path="${2-}"
      shift 2
      ;;
    --no-policy)
      enforce_policy=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      print -u2 "installer-contract-impact: unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n $base_ref && -n $head_ref ]] || {
  print -u2 "installer-contract-impact: --base and --head are required"
  exit 2
}

for command_name in git jq sort tr; do
  (( $+commands[$command_name] )) || {
    print -u2 "installer-contract-impact: required command not found: $command_name"
    exit 2
  }
done

repository="$(command git -C "$repository" rev-parse --show-toplevel)"
typeset temp_dir
temp_dir="$(command mktemp -d "${TMPDIR:-/tmp}/src-contract.XXXXXXXX")"
trap 'command rm -rf -- "$temp_dir"' EXIT INT TERM

typeset empty_manifest='{"schema_version":1,"contract_version":0,"renames":[],"surfaces":[],"consumers":[]}'
typeset base_manifest="$temp_dir/base-manifest.json"
typeset head_manifest="$temp_dir/head-manifest.json"

materialize_manifest() {
  local ref="$1" destination="$2"
  if ! command git -C "$repository" show "${ref}:${manifest_path}" > "$destination" 2>/dev/null; then
    print -r -- "$empty_manifest" > "$destination"
  fi
}

validate_manifest() {
  local file="$1" label="$2"
  jq -e '
    . as $manifest
    | .schema_version == 1
    and (.contract_version | type == "number" and . >= 0 and floor == .)
    and (.renames | type == "array")
    and (.surfaces | type == "array")
    and (.consumers | type == "array")
    and all(.surfaces[];
      . as $surface
      | (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]*$"))
      and (.description | type == "string" and length > 0)
      and (.paths | type == "array" and length > 0)
      and all(.paths[]; type == "string" and length > 0 and (startswith("/") | not) and (contains("..") | not))
    )
    and ([.surfaces[].id] | length == (unique | length))
    and all(.consumers[];
      . as $consumer
      | ("https://github.com/" + $consumer.repository + "/blob/") as $prefix
      | ($consumer.repository | type == "string" and test("^z-shell/[A-Za-z0-9_.-]+$"))
      and ($consumer.path | type == "string" and length > 0 and (startswith("/") | not) and (contains("..") | not))
      and ($consumer.surfaces | type == "array" and length > 0)
      and ($consumer.scope | IN("internal", "external"))
      and ($consumer.evidence_status | IN("internal", "pending", "published"))
      and (
        if $consumer.scope == "internal" then
          $consumer.repository == "z-shell/src"
          and $consumer.evidence_status == "internal"
          and $consumer.evidence == null
        else
          $consumer.repository != "z-shell/src"
          and ($consumer.evidence_status | IN("pending", "published"))
          and (
            if $consumer.evidence_status == "published" then
              ($consumer.evidence | type == "string")
              and ($consumer.evidence | startswith($prefix))
              and (($consumer.evidence | ltrimstr($prefix)) | (test("^[0-9a-f]{40}/") and (.[41:] == $consumer.path)))
            elif $consumer.evidence_status == "pending" then
              $consumer.evidence == null
              or (
                ($consumer.evidence | type == "string")
                and ($consumer.evidence | startswith($prefix))
                and (($consumer.evidence | ltrimstr($prefix)) | (test("^[0-9a-f]{40}/") and (.[41:] == $consumer.path)))
              )
            else
              false
            end
          )
        end
      )
    )
    and ([.consumers[].surfaces[]] - [.surfaces[].id] | length == 0)
    and ([
      .surfaces[].id
      | . as $id
      | any($manifest.consumers[]; .surfaces | index($id))
    ] | all)
    and ([.consumers[] | (.repository + ":" + .path)] | length == (unique | length))
  ' "$file" >/dev/null || {
    print -u2 "installer-contract-impact: invalid ${label} manifest: ${manifest_path}"
    exit 2
  }
}

materialize_manifest "$base_ref" "$base_manifest"
materialize_manifest "$head_ref" "$head_manifest"
validate_manifest "$base_manifest" base
validate_manifest "$head_manifest" head

integer is_bootstrap=0
integer base_contract_version head_contract_version
base_contract_version="$(jq -r '.contract_version' "$base_manifest")"
head_contract_version="$(jq -r '.contract_version' "$head_manifest")"

if (( base_contract_version == 0 )); then
  is_bootstrap=1
fi

typeset -a impacts=()

strip_html_comments() {
  local input="$1" line remaining visible="" visible_line before
  integer in_comment=0

  for line in "${(@f)input}"; do
    remaining="$line"
    visible_line=""
    while [[ -n $remaining ]]; do
      if (( in_comment )); then
        if [[ $remaining == *'-->'* ]]; then
          remaining="${remaining#*'-->'}"
          visible_line+=" "
          in_comment=0
        else
          remaining=""
        fi
      elif [[ $remaining == *'<!--'* ]]; then
        before="${remaining%%'<!--'*}"
        visible_line+="${before} "
        remaining="${remaining#*'<!--'}"
        in_comment=1
      else
        visible_line+="$remaining"
        remaining=""
      fi
    done
    visible+="${visible_line}"$'\n'
  done

  print -r -- "$visible"
}

record_impact() {
  local severity="$1" classification="$2" surface="$3" detail="$4" summary="$5"
  impacts+=( "${severity}"$'\x1f'"${classification}"$'\x1f'"${surface}"$'\x1f'"${detail}"$'\x1f'"${summary}" )
}

# 1. Compare surfaces between base and head
typeset -a base_surface_ids head_surface_ids all_surface_ids
base_surface_ids=( "${(@f)$(jq -r '.surfaces[].id' "$base_manifest")}" )
head_surface_ids=( "${(@f)$(jq -r '.surfaces[].id' "$head_manifest")}" )
all_surface_ids=( "${(@f)$(jq -r -s '[.[].surfaces[].id] | unique[]' "$base_manifest" "$head_manifest")}" )

typeset surface_id base_surface head_surface
for surface_id in "${all_surface_ids[@]}"; do
  [[ -n $surface_id ]] || continue
  base_surface="$(jq -c --arg id "$surface_id" '.surfaces[] | select(.id == $id)' "$base_manifest")"
  head_surface="$(jq -c --arg id "$surface_id" '.surfaces[] | select(.id == $id)' "$head_manifest")"

  if [[ -z $base_surface ]]; then
    if (( ! is_bootstrap )); then
      record_impact info surface-addition "$surface_id" "" \
        "Surface \`${surface_id}\` was added to the installer contract."
    fi
    continue
  fi

  if [[ -z $head_surface ]]; then
    record_impact breaking surface-removal "$surface_id" "" \
      "Surface \`${surface_id}\` was removed from the installer contract."
    continue
  fi

  # Check if surface paths definition changed
  typeset base_paths head_paths
  base_paths="$(jq -Sc '.paths | sort' <<< "$base_surface")"
  head_paths="$(jq -Sc '.paths | sort' <<< "$head_surface")"
  if [[ $base_paths != "$head_paths" ]]; then
    record_impact breaking contract-definition-change "$surface_id" "paths-changed" \
      "Surface \`${surface_id}\` paths definition changed: ${base_paths} -> ${head_paths}"
  fi

  # Check if any declared source path content changed between base and head
  typeset -a surface_paths changed_paths=()
  surface_paths=( "${(@f)$(jq -r '.paths[]' <<< "$head_surface")}" )
  typeset p base_blob head_blob
  for p in "${surface_paths[@]}"; do
    [[ -n $p ]] || continue
    base_blob="$(command git -C "$repository" rev-parse "${base_ref}:${p}" 2>/dev/null || true)"
    head_blob="$(command git -C "$repository" rev-parse "${head_ref}:${p}" 2>/dev/null || true)"
    if [[ $base_blob != "$head_blob" ]]; then
      changed_paths+=( "$p" )
    fi
  done

  if (( ${#changed_paths} )) && (( ! is_bootstrap )); then
    record_impact breaking source-change "$surface_id" "${(j:, :)changed_paths}" \
      "Declared installer source path(s) changed: \`${(j:`, `:)changed_paths}\`."
  fi
done

# 2. Compare consumers between base and head (if not bootstrap)
if (( ! is_bootstrap )); then
  typeset -A base_consumers=() head_consumers=() base_consumer_shapes=() head_consumer_shapes=()
  typeset c_repo c_path c_status c_evidence key

  while IFS=$'\t' read -r c_repo c_path c_status c_evidence; do
    [[ -n $c_repo ]] || continue
    key="${c_repo}:${c_path}"
    base_consumers[$key]="${c_status}"$'\t'"${c_evidence}"
  done < <(jq -r '.consumers[] | [.repository, .path, .evidence_status, (.evidence // "")] | @tsv' "$base_manifest")

  while IFS=$'\t' read -r key c_evidence; do
    [[ -n $key ]] || continue
    base_consumer_shapes[$key]="$c_evidence"
  done < <(jq -r '.consumers[] | [(.repository + ":" + .path), ({scope, surfaces} | @json)] | @tsv' "$base_manifest")

  while IFS=$'\t' read -r c_repo c_path c_status c_evidence; do
    [[ -n $c_repo ]] || continue
    key="${c_repo}:${c_path}"
    head_consumers[$key]="${c_status}"$'\t'"${c_evidence}"
  done < <(jq -r '.consumers[] | [.repository, .path, .evidence_status, (.evidence // "")] | @tsv' "$head_manifest")

  while IFS=$'\t' read -r key c_evidence; do
    [[ -n $key ]] || continue
    head_consumer_shapes[$key]="$c_evidence"
  done < <(jq -r '.consumers[] | [(.repository + ":" + .path), ({scope, surfaces} | @json)] | @tsv' "$head_manifest")

  for key in ${(ok)base_consumers}; do
    if (( ! ${+head_consumers[$key]} )); then
      record_impact breaking consumer-removal "$key" "" \
        "Consumer \`${key}\` was removed from the manifest."
    elif [[ ${base_consumer_shapes[$key]} != ${head_consumer_shapes[$key]} ]]; then
      record_impact breaking consumer-contract-change "$key" "" \
        "Consumer \`${key}\` scope or surface mapping changed."
    elif [[ ${base_consumers[$key]} != ${head_consumers[$key]} ]]; then
      record_impact info consumer-evidence-refresh "$key" "" \
        "Consumer \`${key}\` evidence status was updated."
    fi
  done

  for key in ${(ok)head_consumers}; do
    if (( ! ${+base_consumers[$key]} )); then
      record_impact info consumer-addition "$key" "" \
        "Consumer \`${key}\` was added to the manifest."
    fi
  done
fi

# 3. Build Markdown report
typeset report="$temp_dir/report.md"
{
  print "## Public installer contract impact"
  print
  print -r -- "- Base: \`${base_ref}\`"
  print -r -- "- Head: \`${head_ref}\`"
  print -r -- "- Definition: \`${manifest_path}\` (schema v1, contract v${head_contract_version})"
  print

  if (( is_bootstrap )); then
    print "### Installer contract bootstrap"
    print
    print "Base ref has no trusted installer contract. Introducing contract version v${head_contract_version}."
    print
  fi

  print "### Monitored surfaces"
  print
  jq -r '.surfaces[] | "- `\(.id)` - \(.description) (paths: `\(.paths | join("`, `"))`)"' "$head_manifest"
  print

  if (( ! ${#impacts} )); then
    print "No installer contract changes detected."
  else
    print "### Impacts"
    print
    print "| Classification | Surface | Change | Policy |"
    print "| --- | --- | --- | --- |"
    for impact in "${impacts[@]}"; do
      IFS=$'\x1f' read -r severity classification surface detail summary <<< "$impact"
      if [[ $severity == breaking ]]; then
        policy="breaking gate"
      else
        policy="informational"
      fi
      print "| \`${classification}\` | \`${surface}\` | ${summary} | ${policy} |"
    done
    print

    print "### Affected consumers"
    print
    typeset -A reported_surfaces=()
    for impact in "${impacts[@]}"; do
      IFS=$'\x1f' read -r severity classification surface detail summary <<< "$impact"
      (( ${+reported_surfaces[$surface]} )) && continue
      reported_surfaces[$surface]=1
      print "#### \`${surface}\`"
      typeset consumer_lines
      consumer_lines="$(jq -r --arg surface "$surface" '
        .consumers[]
        | select(.surfaces | index($surface))
        | "- `\(.repository):\(.path)` (\(.scope), \(.evidence_status)\(if .evidence then ", [evidence](\(.evidence))" else "" end))"
      ' "$head_manifest")"
      if [[ -n $consumer_lines ]]; then
        print -r -- "$consumer_lines"
      else
        print -r -- "- No consumer currently registered for this surface."
      fi
      print
    done
  fi
} > "$report"

# 4. Process annotations
typeset -a breaking_impacts=()
typeset severity classification surface detail summary annotation_message
for impact in "${impacts[@]}"; do
  IFS=$'\x1f' read -r severity classification surface detail summary <<< "$impact"
  [[ $severity == breaking ]] && breaking_impacts+=( "$impact" )
  annotation_message="${surface}: ${summary}"
  annotation_message="${annotation_message//'%'/'%25'}"
  annotation_message="${annotation_message//$'\r'/'%0D'}"
  annotation_message="${annotation_message//$'\n'/'%0A'}"
  if [[ $severity == breaking ]]; then
    print "::error title=Installer contract ${classification}::${annotation_message}"
  else
    print "::notice title=Installer contract ${classification}::${annotation_message}"
  fi
done

# 5. Enforce policy
integer policy_failures=0
if (( enforce_policy && ${#breaking_impacts} )); then
  # Check 1: Contract-version bump required
  if (( head_contract_version <= base_contract_version )); then
    print "::error title=Contract-version bump required::Contract version in ${manifest_path} must be bumped from ${base_contract_version} to $(( base_contract_version + 1 )) (or higher) because installer source paths changed."
    (( policy_failures += 1 ))
  fi

  # Check 2: Explicit PR-body consumer-impact acknowledgement
  typeset pr_body="${PR_BODY-}"
  typeset visible_pr_body
  visible_pr_body="$(strip_html_comments "$pr_body")"

  typeset -A acknowledged_surfaces=()
  typeset marker body_line trimmed_line disposition

  for impact in "${breaking_impacts[@]}"; do
    IFS=$'\x1f' read -r severity classification surface detail summary <<< "$impact"
    marker="[installer-impact:${surface}]"
    disposition=""
    for body_line in "${(@f)visible_pr_body}"; do
      trimmed_line="${body_line##[[:space:]]#}"
      if [[ ${trimmed_line[1,${#marker}]-} == "$marker" ]]; then
        disposition="${trimmed_line[${#marker}+1,-1]-}"
        disposition="${disposition##[[:space:]]#}"
        break
      fi
    done

    if [[ -n $disposition ]]; then
      if [[ $disposition == "updated here"* ]] ||
         [[ $disposition == "acknowledged"* ]] ||
         [[ $disposition == "follow-up issue linked:"*https://github.com/*/issues/<->* ]] ||
         [[ ${#disposition} -ge 15 && $disposition == "not affected:"?* ]] ||
         [[ $disposition == "deprecated with removal target:"?* ]]; then
        acknowledged_surfaces[$surface]=1
        continue
      fi
    fi

    print "::error title=Consumer-impact acknowledgement required::Add ${marker} followed by an allowed disposition to the PR body."
    (( policy_failures += 1 ))
  done

  # Check 3: Every affected consumer must carry fresh review evidence. Internal
  # consumers prove that review with a changed blob in this PR. External
  # consumers prove it with a new immutable commit URL in the manifest.
  typeset -A impacted_surface_ids=() checked_consumers=()
  for impact in "${breaking_impacts[@]}"; do
    IFS=$'\x1f' read -r severity classification surface detail summary <<< "$impact"
    if jq -e --arg id "$surface" '.surfaces[] | select(.id == $id)' "$head_manifest" >/dev/null; then
      impacted_surface_ids[$surface]=1
    fi
  done

  typeset consumer_scope consumer_surfaces base_evidence head_evidence base_blob head_blob
  while IFS=$'\t' read -r c_repo c_path consumer_scope c_status head_evidence consumer_surfaces; do
    key="${c_repo}:${c_path}"
    (( ${+checked_consumers[$key]} )) && continue

    integer is_affected=0
    for surface_id in ${(s:,:)consumer_surfaces}; do
      if (( ${+impacted_surface_ids[$surface_id]} )); then
        is_affected=1
        break
      fi
    done
    (( is_affected )) || continue
    checked_consumers[$key]=1

    if [[ $consumer_scope == internal ]]; then
      base_blob="$(command git -C "$repository" rev-parse "${base_ref}:${c_path}" 2>/dev/null || true)"
      head_blob="$(command git -C "$repository" rev-parse "${head_ref}:${c_path}" 2>/dev/null || true)"
      if [[ -z $head_blob || $base_blob == "$head_blob" ]]; then
        print "::error title=Internal consumer refresh required::Update ${c_path} to reflect or re-attest the impacted installer surface."
        (( policy_failures += 1 ))
      fi
      continue
    fi

    base_evidence="$(jq -r --arg repo "$c_repo" --arg path "$c_path" '.consumers[] | select(.repository == $repo and .path == $path) | (.evidence // "-")' "$base_manifest")"
    if [[ $c_status != published || $head_evidence == "-" || $head_evidence == "$base_evidence" ]]; then
      print "::error title=External consumer evidence refresh required::Publish or re-attest ${key}, then record its new immutable commit URL in ${manifest_path}."
      (( policy_failures += 1 ))
    fi
  done < <(jq -r '.consumers[] | [.repository, .path, .scope, .evidence_status, (.evidence // "-"), (.surfaces | join(","))] | @tsv' "$head_manifest")
fi

if (( ${#breaking_impacts} )); then
  {
    print
    print "### Required PR-body acknowledgements"
    print
    print "Changes to installer source paths require an explicit acknowledgement line in the PR body for each impacted surface:"
    print
    typeset -A listed_surfaces=()
    for impact in "${breaking_impacts[@]}"; do
      IFS=$'\x1f' read -r severity classification surface detail summary <<< "$impact"
      (( ${+listed_surfaces[$surface]} )) && continue
      listed_surfaces[$surface]=1
      print -r -- "- \`[installer-impact:${surface}] updated here\`"
    done
    print
    print "Allowed dispositions: \`updated here\`, \`acknowledged\`, \`follow-up issue linked: <issue URL>\`, \`not affected: <rationale>\`, \`deprecated with removal target: <target>\`."
  } >> "$report"
fi

command cat "$report"
if [[ -n ${GITHUB_STEP_SUMMARY-} ]]; then
  command cat "$report" >> "$GITHUB_STEP_SUMMARY"
fi

if (( policy_failures > 0 )); then
  exit 1
fi

exit 0
