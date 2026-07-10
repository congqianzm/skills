#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# install-codebuddy.sh
#
# Sync upstream mattpocock/skills and auto-install adapted skills to
# CodeBuddy's user-level skill directory.
#
# Compatible with: Bash 3.2+ (macOS default), Linux, WSL
#
# The upstream skills/ directory is the SINGLE SOURCE OF TRUTH.
# This script auto-converts Claude-format skills into CodeBuddy format,
# applies local patches, and installs to ~/.codebuddy/skills/.
#
# Usage:
#   ./scripts/install-codebuddy.sh              # full sync + install
#   ./scripts/install-codebuddy.sh --skip-sync  # install only (offline)
#   ./scripts/install-codebuddy.sh --skills-dir /custom/path
# =============================================================================

# --- Configuration ---
UPSTREAM_REMOTE="upstream"
UPSTREAM_URL="https://github.com/mattpocock/skills.git"
UPSTREAM_BRANCH="main"

# Skill map: "output_name:source_path" pairs
SKILL_MAP="
grill-with-docs:skills/engineering/grill-with-docs
to-prd:skills/engineering/to-spec
to-issues:skills/engineering/to-tickets
implement:skills/engineering/implement
code-review:skills/engineering/code-review
"

# Shell skills lookup: returns space-separated referenced skill paths
# for skills whose body is just "Run a /X session"
get_shell_skill_refs() {
    case "$1" in
        "skills/engineering/grill-with-docs")
            echo "skills/productivity/grilling skills/engineering/domain-modeling"
            ;;
        *)
            echo ""
            ;;
    esac
}

# --- Parse arguments ---
SKIP_SYNC=false
SKILLS_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-sync) SKIP_SYNC=true; shift ;;
        --skills-dir) SKILLS_DIR="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--skip-sync] [--skills-dir DIR]"
            echo ""
            echo "Options:"
            echo "  --skip-sync    Skip upstream git sync (useful when offline)"
            echo "  --skills-dir   Override CodeBuddy skills directory"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCHES_DIR="$REPO_ROOT/.codebuddy/patches"

if [ -z "$SKILLS_DIR" ]; then
    SKILLS_DIR="$HOME/.codebuddy/skills"
fi

# --- Helpers ---
step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m[OK]\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m[!!]\033[0m %s\n' "$1"; }

# --- Extract body from SKILL.md (everything after second ---) ---
extract_body() {
    awk '/^---$/{c++; if(c==2){found=1; next}} found{print}' "$1"
}

# --- Extract frontmatter including both --- delimiters ---
extract_frontmatter() {
    awk '/^---$/{c++; print; if(c==2){exit}} c>=1{print}' "$1"
}

# --- Convert a single skill ---
convert_skill() {
    local source_path="$1"
    local output_name="$2"
    local skill_file="$REPO_ROOT/$source_path/SKILL.md"

    if [ ! -f "$skill_file" ]; then
        warn "Source not found: $skill_file"
        return 1
    fi

    local content
    content="$(cat "$skill_file")"

    # Transform 1: Remove disable-model-invocation
    content="$(printf '%s' "$content" | sed '/^disable-model-invocation:.*$/d')"

    # Transform 2: Replace /skill-name references
    # Note: macOS sed -E is equivalent to GNU sed -r
    content="$(printf '%s' "$content" | sed -E 's|`/([a-z-]+)`|`\1` 技能|g')"
    content="$(printf '%s' "$content" | sed -E 's| /([a-z-]+)([^a-z-])| `\1` 技能\2|g')"

    # Transform 3: Handle shell skills (inline referenced content)
    local refs
    refs="$(get_shell_skill_refs "$source_path")"

    if [ -n "$refs" ]; then
        # Check if it's a thin shell (body <= 3 meaningful lines)
        local body
        body="$(extract_body "$skill_file")"
        # Apply transforms 1&2 to body for counting
        body="$(printf '%s' "$body" | sed '/^disable-model-invocation:.*$/d')"
        local meaningful_lines
        meaningful_lines="$(printf '%s' "$body" | grep -c '[^ ]' || true)"

        if [ "$meaningful_lines" -le 3 ]; then
            # Extract frontmatter
            local frontmatter
            frontmatter="$(extract_frontmatter "$skill_file")"
            # Apply transform 1 to frontmatter
            frontmatter="$(printf '%s' "$frontmatter" | sed '/^disable-model-invocation:.*$/d')"

            # Build inlined body from referenced skills
            local inlined_body=""
            for ref in $refs; do
                local ref_file="$REPO_ROOT/$ref/SKILL.md"
                if [ -f "$ref_file" ]; then
                    local ref_body
                    ref_body="$(extract_body "$ref_file")"
                    # Clean /skill references in inlined content
                    ref_body="$(printf '%s' "$ref_body" | sed -E 's|`/([a-z-]+)`|`\1` 技能|g')"
                    ref_body="$(printf '%s' "$ref_body" | sed -E 's| /([a-z-]+)([^a-z-])| `\1` 技能\2|g')"
                    inlined_body="$inlined_body
$ref_body
"
                fi
            done
            content="$frontmatter

$inlined_body"
        fi
    fi

    # Transform 4: Rename skill
    if [ -n "$output_name" ]; then
        content="$(printf '%s' "$content" | sed -E "s/^name:.*/name: $output_name/")"
    fi

    # Transform 5: Remove setup-matt-pocock-skills references
    content="$(printf '%s' "$content" | sed '/setup-matt-pocock-skills/d')"

    printf '%s' "$content"
}

# =============================================================================
# Step 1: Sync upstream
# =============================================================================
if [ "$SKIP_SYNC" = "false" ]; then
    step "Syncing with upstream ($UPSTREAM_URL)"

    cd "$REPO_ROOT"

    # Ensure upstream remote exists
    if ! git remote | grep -q "^${UPSTREAM_REMOTE}$"; then
        git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
        ok "Added remote '$UPSTREAM_REMOTE'"
    fi

    # Fetch
    git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" 2>/dev/null
    ok "Fetched $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"

    # Merge if on main
    current_branch="$(git branch --show-current)"
    if [ "$current_branch" = "main" ]; then
        if git merge "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" --no-edit 2>/dev/null; then
            ok "Merged upstream/main"
        else
            warn "Merge conflict! Resolve manually, then re-run."
            exit 1
        fi
    else
        warn "Not on main (current: $current_branch), skipping merge"
    fi
else
    step "Skipping upstream sync (--skip-sync)"
fi

# =============================================================================
# Step 2: Convert and install
# =============================================================================
step "Converting and installing skills"

mkdir -p "$SKILLS_DIR"

installed=0

# Process each skill in SKILL_MAP
printf '%s\n' "$SKILL_MAP" | while IFS= read -r entry; do
    # Skip empty lines
    [ -z "$entry" ] && continue

    output_name="${entry%%:*}"
    source_path="${entry#*:}"
    dest_dir="$SKILLS_DIR/$output_name"

    # Convert
    converted="$(convert_skill "$source_path" "$output_name")" || {
        warn "$output_name — conversion failed, skipping"
        continue
    }

    # Apply patch if exists
    patch_file="$PATCHES_DIR/$output_name.patch.md"
    if [ -f "$patch_file" ]; then
        converted="$converted

$(cat "$patch_file")"
        printf '    (applied patch)\n'
    fi

    # Write to destination
    mkdir -p "$dest_dir"
    printf '%s' "$converted" > "$dest_dir/SKILL.md"

    # Copy bundled resources
    src_full="$REPO_ROOT/$source_path"
    for subdir in scripts references assets; do
        if [ -d "$src_full/$subdir" ]; then
            rm -rf "${dest_dir:?}/$subdir"
            cp -r "$src_full/$subdir" "$dest_dir/$subdir"
        fi
    done

    ok "$output_name (from $source_path)"
    installed=$((installed + 1))
done

# =============================================================================
# Summary
# =============================================================================
step "Done! Skills installed to $SKILLS_DIR"
echo ""
echo "  Workflow:"
echo "    1. /grill-with-docs  — 把想法磨清楚 + 构建领域模型"
echo "    2. /to-prd           — 把对话合成一份PRD"
echo "    3. /to-issues        — 把PRD切成独立issue"
echo "    4. /implement        — 每个issue实现"
echo "    5. /code-review      — 写完收尾评审"
echo ""
echo "  Re-run this script anytime to pick up upstream changes."
echo ""
