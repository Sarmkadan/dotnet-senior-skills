#!/usr/bin/env bash
# Usage: scripts/verify-install.sh [--tools TOOLS] [target-project-dir]
# Checks that each agent tool can discover the rule files installed in a target project.
# Prints PASS / FAIL / SKIP per tool and exits 1 if any tool FAILs.
#
# Options:
# --tools TOOLS Comma-separated tools that must be installed (claude,cursor,copilot,agents,windsurf,cline).
#               A requested tool that is missing FAILs. Default: check the tools that are present, SKIP the rest.
#
# Discovery layouts checked (current as of 2026):
#   claude    .claude/skills/<name>/SKILL.md, name == directory. Nothing shallower or deeper is loaded.
#   cursor    .cursor/rules/*.mdc with frontmatter. Fallback: legacy .cursorrules (still read, but deprecated).
#   copilot   .github/copilot-instructions.md (repository-wide). Fallback: .github/instructions/**/*.instructions.md
#             with an applyTo pattern (path-specific).
#   agents    AGENTS.md at the project root (read by Copilot, Cursor, Codex and other agents).
#   windsurf  .windsurf/rules/*.md. Fallback: single .windsurfrules file at the root (legacy).
#   cline     .clinerules/ folder with *.md (or *.txt) files. Fallback: single .clinerules file.
set -euo pipefail

ALL_TOOLS="claude cursor copilot agents windsurf cline"
TARGET=""
REQUESTED_TOOLS=""

CURRENT_FAILS=0
CURRENT_SKIPPED=0
RESULT_NAMES=()
RESULT_STATUSES=()

usage() {
  echo "Usage: $0 [--tools TOOLS] [target-project-dir]" >&2
}

# --- Argument parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    --tools)
      if [ $# -lt 2 ] || [ "${2:0:1}" = "-" ]; then
        echo "Error: --tools requires a comma-separated list of tools" >&2
        usage
        exit 2
      fi
      REQUESTED_TOOLS="${2,,}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [ -n "$TARGET" ]; then
        echo "Error: multiple targets specified" >&2
        usage
        exit 2
      fi
      TARGET="$1"
      shift
      ;;
  esac
done

TARGET="${TARGET:-.}"
if [ ! -d "$TARGET" ]; then
  echo "Error: target directory does not exist: $TARGET" >&2
  exit 2
fi
TARGET="$(cd "$TARGET" && pwd)"

for tool in ${REQUESTED_TOOLS//,/ }; do
  case " $ALL_TOOLS " in
    *" $tool "*) ;;
    *)
      echo "Error: invalid tool specified: $tool (valid: ${ALL_TOOLS// /, })" >&2
      exit 2
      ;;
  esac
done

# --- Helpers ---

# Reporting. fail() counts toward the current tool's status; absent() marks the tool as not installed.
ok()        { printf '  ok    %s\n' "$*"; }
note()      { printf '  note  %s\n' "$*"; }
fail()      { printf '  FAIL  %s\n' "$*"; CURRENT_FAILS=$((CURRENT_FAILS + 1)); }
absent()    { printf '  not installed: %s\n' "$*"; CURRENT_SKIPPED=1; }

# Path relative to the target, for readable messages.
rel() { printf '%s' "${1#"$TARGET"/}"; }

is_requested() {
  case ",$REQUESTED_TOOLS," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

# Succeeds if the file starts with a YAML frontmatter fence.
has_frontmatter() { [ "$(head -n 1 "$1")" = "---" ]; }

# Prints the value of <key> from the leading frontmatter block. Returns 1 when the key is absent.
frontmatter_get() {
  awk -v key="$2" '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    index($0, key ":") == 1 { sub("^" key ":[ \t]*", ""); print; found = 1; exit }
    END { exit !found }
  ' "$1"
}

# Runs one tool's check, then records PASS, FAIL or SKIP for the summary.
run_check() { # <tool> <expected layout> <check function>
  local tool="$1" layout="$2" check="$3" status
  CURRENT_FAILS=0
  CURRENT_SKIPPED=0

  printf '%s  (%s)\n' "$tool" "$layout"
  "$check"
  if [ "$CURRENT_SKIPPED" -eq 1 ] && is_requested "$tool"; then
    fail "requested via --tools but not installed"
  fi

  if [ "$CURRENT_FAILS" -gt 0 ]; then
    status=FAIL
  elif [ "$CURRENT_SKIPPED" -eq 1 ]; then
    status=SKIP
  else
    status=PASS
  fi
  RESULT_NAMES+=("$tool")
  RESULT_STATUSES+=("$status")
  echo
}

# --- Tool checks ---

check_claude() {
  local skills="$TARGET/.claude/skills" file stray dir_name name count=0
  if [ ! -d "$skills" ]; then
    absent ".claude/skills/ not found"
    return 0
  fi

  while IFS= read -r stray; do
    fail "$(rel "$stray"): too shallow, Claude Code loads only .claude/skills/<name>/SKILL.md"
  done < <(find "$skills" -maxdepth 1 -type f -name '*.md')
  while IFS= read -r stray; do
    fail "$(rel "$stray"): nested too deep, expected .claude/skills/<name>/SKILL.md"
  done < <(find "$skills" -mindepth 3 -name SKILL.md)

  while IFS= read -r file; do
    count=$((count + 1))
    dir_name="$(basename "$(dirname "$file")")"
    if [[ ! "$dir_name" =~ ^[a-z0-9-]{1,64}$ ]]; then
      fail "$(rel "$file"): directory name must match ^[a-z0-9-]{1,64}\$"
    fi
    if ! has_frontmatter "$file"; then
      fail "$(rel "$file"): no YAML frontmatter (the first line must be exactly ---)"
      continue
    fi
    if name="$(frontmatter_get "$file" name)"; then
      name="${name//[\"\']/}"
      [ "$name" = "$dir_name" ] || fail "$(rel "$file"): frontmatter name '$name' does not match directory '$dir_name'"
    else
      fail "$(rel "$file"): frontmatter has no name:"
    fi
    frontmatter_get "$file" description >/dev/null || fail "$(rel "$file"): frontmatter has no description: (Claude uses it to decide when to load the skill)"
  done < <(find "$skills" -mindepth 2 -maxdepth 2 -name SKILL.md | sort)

  if [ "$count" -eq 0 ]; then
    fail "no .claude/skills/<name>/SKILL.md files found"
  else
    ok "$count skill(s) at .claude/skills/<name>/SKILL.md"
  fi
  return 0
}

check_cursor() {
  local rules="$TARGET/.cursor/rules" legacy="$TARGET/.cursorrules" file count=0
  if [ ! -d "$rules" ] && [ ! -f "$legacy" ]; then
    absent ".cursor/rules/ and .cursorrules not found"
    return 0
  fi
  if [ ! -d "$rules" ]; then
    fail ".cursorrules only: the legacy single file; current Cursor layout is .cursor/rules/*.mdc"
    return 0
  fi
  if [ -f "$legacy" ]; then
    note ".cursorrules is also present; remove it so rules come from one place"
  fi

  while IFS= read -r file; do
    case "$file" in
      *.mdc) ;;
      *)
        note "$(rel "$file") is ignored by Cursor (only *.mdc files are loaded)"
        continue
        ;;
    esac
    count=$((count + 1))
    if [ ! -s "$file" ]; then
      fail "$(rel "$file"): empty rule file"
      continue
    fi
    if ! has_frontmatter "$file"; then
      fail "$(rel "$file"): no frontmatter, so the rule is never attached automatically (only via @-mention)"
      continue
    fi
    if ! frontmatter_get "$file" description >/dev/null \
      && ! frontmatter_get "$file" globs >/dev/null \
      && ! frontmatter_get "$file" alwaysApply >/dev/null; then
      fail "$(rel "$file"): frontmatter needs description, globs or alwaysApply"
    fi
  done < <(find "$rules" -mindepth 1 -maxdepth 1 -type f | sort)

  if [ "$count" -eq 0 ]; then
    fail "no *.mdc files in .cursor/rules/"
  else
    ok "$count rule file(s) at .cursor/rules/*.mdc"
  fi
  return 0
}

check_copilot() {
  local main="$TARGET/.github/copilot-instructions.md" dir="$TARGET/.github/instructions" file path_count=0
  if [ -f "$main" ]; then
    if [ -s "$main" ]; then
      ok ".github/copilot-instructions.md (repository-wide)"
    else
      fail ".github/copilot-instructions.md is empty"
    fi
  fi

  if [ -d "$dir" ]; then
    while IFS= read -r file; do
      case "$file" in
        *.instructions.md) ;;
        *)
          fail "$(rel "$file"): never discovered, path-specific files must be named *.instructions.md"
          continue
          ;;
      esac
      if ! frontmatter_get "$file" applyTo >/dev/null; then
        fail "$(rel "$file"): no applyTo pattern, so it never matches a file"
        continue
      fi
      path_count=$((path_count + 1))
    done < <(find "$dir" -type f | sort)
    if [ "$path_count" -gt 0 ]; then
      ok "$path_count path-specific file(s) at .github/instructions/*.instructions.md"
    fi
  fi

  if [ ! -f "$main" ] && [ "$path_count" -eq 0 ]; then
    if [ -f "$TARGET/copilot-instructions.md" ] || [ -d "$TARGET/.github/copilot-instructions" ]; then
      fail "copilot instructions are in the wrong place, the file must be .github/copilot-instructions.md"
    elif [ ! -d "$dir" ]; then
      absent ".github/copilot-instructions.md and .github/instructions/ not found"
    else
      fail ".github/instructions/ contains no valid *.instructions.md files"
    fi
  fi
  return 0
}

check_agents() {
  local file="$TARGET/AGENTS.md" misnamed
  if [ -f "$file" ]; then
    if [ -s "$file" ]; then
      ok "AGENTS.md at the project root"
    else
      fail "AGENTS.md is empty"
    fi
    return 0
  fi

  misnamed="$(find "$TARGET" -maxdepth 1 -iname 'agents.md' -print -quit)"
  if [ -n "$misnamed" ]; then
    fail "$(rel "$misnamed"): name must be exactly AGENTS.md (file names are case-sensitive on Linux)"
    return 0
  fi
  absent "AGENTS.md not found"
  return 0
}

check_windsurf() {
  local rules="$TARGET/.windsurf/rules" legacy="$TARGET/.windsurfrules" file size count=0
  if [ -d "$legacy" ]; then
    fail ".windsurfrules/ is a directory and Windsurf never reads it, use .windsurf/rules/*.md or a single .windsurfrules file"
  fi

  if [ -d "$rules" ]; then
    while IFS= read -r file; do
      case "$file" in
        *.md) ;;
        *)
          note "$(rel "$file") is ignored by Windsurf (only *.md files are loaded)"
          continue
          ;;
      esac
      count=$((count + 1))
      size="$(wc -c < "$file" | tr -d ' ')"
      if [ "$size" -gt 12000 ]; then
        note "$(rel "$file") is $size bytes, Windsurf is reported to truncate workspace rules above 12000 characters"
      fi
    done < <(find "$rules" -mindepth 1 -maxdepth 1 -type f | sort)

    if [ "$count" -gt 0 ]; then
      ok "$count rule file(s) at .windsurf/rules/*.md"
    else
      fail ".windsurf/rules/ contains no *.md files"
    fi
  elif [ -f "$legacy" ]; then
    ok ".windsurfrules single file (legacy layout, still read)"
  elif [ ! -d "$legacy" ]; then
    absent ".windsurf/rules/ and .windsurfrules not found"
  fi
  return 0
}

check_cline() {
  local dir="$TARGET/.clinerules" file ignored="" ignored_count=0 count=0
  if [ -f "$dir" ]; then
    ok ".clinerules single file (fallback layout)"
    return 0
  fi
  if [ ! -d "$dir" ]; then
    absent ".clinerules/ not found"
    return 0
  fi

  while IFS= read -r file; do
    case "$file" in
      *.md|*.txt) count=$((count + 1)) ;;
      *)
        ignored_count=$((ignored_count + 1))
        ignored="${ignored:-$(rel "$file")}"
        ;;
    esac
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f | sort)

  if [ "$ignored_count" -gt 0 ]; then
    fail "$ignored_count file(s) ignored by Cline, which reads only *.md and *.txt inside .clinerules/ (e.g. $ignored)"
  fi
  if [ "$count" -eq 0 ]; then
    fail ".clinerules/ contains no *.md rule files"
  else
    ok "$count rule file(s) at .clinerules/*.md"
  fi
  return 0
}

# --- Run ---
echo "Verifying agent discovery in $TARGET"
echo

run_check claude   ".claude/skills/<name>/SKILL.md"               check_claude
run_check cursor   ".cursor/rules/*.mdc"                          check_cursor
run_check copilot  ".github/copilot-instructions.md"              check_copilot
run_check agents   "AGENTS.md"                                    check_agents
run_check windsurf ".windsurf/rules/*.md"                         check_windsurf
run_check cline    ".clinerules/*.md"                             check_cline

echo "Summary"
installed=0
overall=0
for i in "${!RESULT_NAMES[@]}"; do
  printf '  %-5s %s\n' "${RESULT_STATUSES[$i]}" "${RESULT_NAMES[$i]}"
  if [ "${RESULT_STATUSES[$i]}" != SKIP ]; then
    installed=$((installed + 1))
  fi
  if [ "${RESULT_STATUSES[$i]}" = FAIL ]; then
    overall=1
  fi
done

if [ "$installed" -eq 0 ]; then
  echo "No installed rule files found in $TARGET" >&2
  exit 1
fi
exit "$overall"
