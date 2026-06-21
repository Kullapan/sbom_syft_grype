#!/bin/bash
# scan-git.sh — Multi-repo Git SBOM scanner
# Supports 3 input modes:
#   1. GIT_REPOS_FILE — path to repos.txt file (one repo per line, optional branch)
#   2. GIT_REPOS    — comma or newline-separated URLs
#   3. GIT_REPO_URL + GIT_BRANCH — single repo (backward compat)
#
# Line format in repos file: <url> [branch]
# Lines starting with # are comments, blank lines are skipped
#
# SAFETY: This script NEVER performs git push, git commit, git add,
#         or any remote-write operation. Read-only clone + scan only.

set -e

# Source shared library
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-common.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────────────────────
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║        SSDLC Pipeline — Multi-Repo Git Scanner              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Validate required environment variables
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "$DTRACK_URL" ] || [ -z "$DTRACK_API_KEY" ]; then
    echo "ERROR: Missing required environment variables."
    echo "  Required: DTRACK_URL, DTRACK_API_KEY"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Set defaults
# ─────────────────────────────────────────────────────────────────────────────
GIT_BRANCH="${GIT_BRANCH:-main}"
GRYPE_SEVERITY="${GRYPE_SEVERITY:-critical}"
GRYPE_MODE="${GRYPE_MODE:-block}"
REPORT_BASE_DIR="${REPORT_BASE_DIR:-/reports}"

echo "  Config:"
echo "    Default Branch:  $GIT_BRANCH"
echo "    Grype Severity:  $GRYPE_SEVERITY"
echo "    Grype Mode:      $GRYPE_MODE"
echo "    Report Dir:      $REPORT_BASE_DIR"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# parse_repos — Output lines of "<url> <branch>" based on input mode
# Priority: GIT_REPOS_FILE > GIT_REPOS > GIT_REPO_URL
# ─────────────────────────────────────────────────────────────────────────────
parse_repos() {
    if [ -n "$GIT_REPOS_FILE" ] && [ -f "$GIT_REPOS_FILE" ]; then
        # Mode 1: Read from file
        echo "  [Input] Reading repos from file: $GIT_REPOS_FILE" >&2
        cat "$GIT_REPOS_FILE"

    elif [ -n "$GIT_REPOS" ]; then
        # Mode 2: Comma or newline-separated list
        echo "  [Input] Reading repos from GIT_REPOS variable" >&2
        echo "$GIT_REPOS" | tr ',' '\n'

    elif [ -n "$GIT_REPO_URL" ]; then
        # Mode 3: Single repo (backward compatibility)
        echo "  [Input] Single repo mode: $GIT_REPO_URL" >&2
        echo "$GIT_REPO_URL $GIT_BRANCH"

    else
        echo "ERROR: No repository input provided." >&2
        echo "  Set one of: GIT_REPOS_FILE, GIT_REPOS, or GIT_REPO_URL" >&2
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Initialize root index
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "$REPORT_BASE_DIR"
init_root_index "$REPORT_BASE_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Main loop — iterate through repos
# ─────────────────────────────────────────────────────────────────────────────
TOTAL=0
FAILED=0

# Read repo list into a temp file so parse_repos' stdout messages don't pollute the loop
REPO_LIST_TMP=$(mktemp)
parse_repos | grep -v '^\s*$' | grep -v '^\s*#' > "$REPO_LIST_TMP" || true

while IFS= read -r line; do
    # Skip empty lines (safety — already filtered above)
    [ -z "$line" ] && continue

    # Extract URL and optional branch from line
    REPO_URL=$(echo "$line" | awk '{print $1}')
    REPO_BRANCH=$(echo "$line" | awk '{print $2}')

    # Default to GIT_BRANCH if no branch specified on the line
    REPO_BRANCH="${REPO_BRANCH:-$GIT_BRANCH}"

    # Derive project name from URL (strip .git suffix)
    PROJECT_NAME=$(basename "$REPO_URL" .git)

    # Set output directory for this repo
    OUTPUT_DIR="${REPORT_BASE_DIR}/${PROJECT_NAME}"
    mkdir -p "$OUTPUT_DIR"

    TOTAL=$((TOTAL + 1))

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    printf "  [%d] Scanning: %s (branch: %s)\n" "$TOTAL" "$PROJECT_NAME" "$REPO_BRANCH"
    echo "═══════════════════════════════════════════════════════════════"

    # ── Step 1: Clone ─────────────────────────────────────────────────
    echo ""
    echo "  [Git] Cloning $REPO_URL (branch: $REPO_BRANCH, depth: 1)"

    # Clean workspace before clone (safety: only remove /workspace)
    rm -rf /workspace

    git clone "$REPO_URL" \
        --branch "$REPO_BRANCH" \
        --depth 1 \
        --single-branch \
        /workspace

    echo "  [Git] Clone complete"

    # ── Step 2: Detect sub-projects (monorepo support) ───────────────
    SUB_PROJECTS_TMP=$(mktemp)
    set +e
    detect_sub_projects /workspace > "$SUB_PROJECTS_TMP"
    IS_MONOREPO=$?
    set -e

    if [ $IS_MONOREPO -eq 0 ]; then
        # ── Monorepo: scan each sub-project separately ───────────────
        sub_count=$(wc -l < "$SUB_PROJECTS_TMP" | tr -d '[:space:]')
        echo ""
        echo "  [Monorepo] Detected $sub_count sub-projects:"
        while IFS=' ' read -r sub_name sub_type; do
            echo "    → ${sub_name} (${sub_type})"
        done < "$SUB_PROJECTS_TMP"

        while IFS=' ' read -r SUB_NAME SUB_TYPE; do
            [ -z "$SUB_NAME" ] && continue
            SUB_PROJECT_NAME="${PROJECT_NAME}-${SUB_NAME}"
            SUB_OUTPUT_DIR="${REPORT_BASE_DIR}/${SUB_PROJECT_NAME}"
            SUB_SCAN_DIR="/workspace/${SUB_NAME}"
            mkdir -p "$SUB_OUTPUT_DIR"

            TOTAL=$((TOTAL + 1))

            echo ""
            echo "  ─────────────────────────────────────────────────────────"
            printf "  [%d] Sub-project: %s (type: %s)\n" "$TOTAL" "$SUB_PROJECT_NAME" "$SUB_TYPE"
            echo "  ─────────────────────────────────────────────────────────"

            # SBOM generation
            run_syft "$SUB_SCAN_DIR" "$SUB_PROJECT_NAME" "$REPO_BRANCH" "$SUB_OUTPUT_DIR"

            # Grype vulnerability scan
            set +e
            run_grype "${SUB_OUTPUT_DIR}/sbom.json" "$GRYPE_SEVERITY" "$GRYPE_MODE" "$SUB_OUTPUT_DIR"
            GRYPE_EXIT=$?
            set -e

            # Upload to Dependency-Track (as separate project)
            set +e
            upload_to_dtrack "${SUB_OUTPUT_DIR}/sbom.json" "$SUB_PROJECT_NAME" "$REPO_BRANCH"
            UPLOAD_EXIT=$?
            set -e

            # Generate per-project summary
            generate_repo_summary "$SUB_PROJECT_NAME" "$REPO_URL" "$REPO_BRANCH" \
                "$SUB_OUTPUT_DIR" "$GRYPE_EXIT" "$UPLOAD_EXIT" "$DTRACK_URL"

            # Append to root index
            append_root_index "$TOTAL" "$SUB_PROJECT_NAME" "$REPO_BRANCH" \
                "$SUB_OUTPUT_DIR" "$GRYPE_EXIT" "$GRYPE_MODE" "$UPLOAD_EXIT"

            # Track failures
            if [ "$GRYPE_MODE" = "block" ] && [ "$GRYPE_EXIT" -ne 0 ]; then
                FAILED=$((FAILED + 1))
            fi

        done < "$SUB_PROJECTS_TMP"
    else
        # ── Single project: scan as before ───────────────────────────
        # SBOM generation
        run_syft /workspace "$PROJECT_NAME" "$REPO_BRANCH" "$OUTPUT_DIR"

        # Cleanup workspace after SBOM generation
        rm -rf /workspace
        echo "  [Cleanup] Workspace cleared"

        # Grype vulnerability scan
        set +e
        run_grype "${OUTPUT_DIR}/sbom.json" "$GRYPE_SEVERITY" "$GRYPE_MODE" "$OUTPUT_DIR"
        GRYPE_EXIT=$?
        set -e

        # Upload to Dependency-Track
        set +e
        upload_to_dtrack "${OUTPUT_DIR}/sbom.json" "$PROJECT_NAME" "$REPO_BRANCH"
        UPLOAD_EXIT=$?
        set -e

        # Generate per-repo summary
        generate_repo_summary "$PROJECT_NAME" "$REPO_URL" "$REPO_BRANCH" \
            "$OUTPUT_DIR" "$GRYPE_EXIT" "$UPLOAD_EXIT" "$DTRACK_URL"

        # Append to root index
        append_root_index "$TOTAL" "$PROJECT_NAME" "$REPO_BRANCH" \
            "$OUTPUT_DIR" "$GRYPE_EXIT" "$GRYPE_MODE" "$UPLOAD_EXIT"

        # Track failures
        if [ "$GRYPE_MODE" = "block" ] && [ "$GRYPE_EXIT" -ne 0 ]; then
            FAILED=$((FAILED + 1))
        fi
    fi

    # ── Cleanup ──────────────────────────────────────────────────────
    rm -rf /workspace
    rm -f "$SUB_PROJECTS_TMP"
    echo "  [Cleanup] Workspace cleared"

done < "$REPO_LIST_TMP"

# Clean up temp file
rm -f "$REPO_LIST_TMP"

# ─────────────────────────────────────────────────────────────────────────────
# Finalize root index
# ─────────────────────────────────────────────────────────────────────────────
finalize_root_index "$REPORT_BASE_DIR" "$TOTAL" "$FAILED" "$GRYPE_MODE"

# ─────────────────────────────────────────────────────────────────────────────
# Final result
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                    Pipeline Complete                         ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
printf "║  Total Repos: %-4s  |  Failed: %-4s  |  Mode: %-12s  ║\n" "$TOTAL" "$FAILED" "$GRYPE_MODE"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

if [ "$GRYPE_MODE" = "block" ] && [ "$FAILED" -gt 0 ]; then
    echo "🚫 Pipeline FAILED — $FAILED repo(s) blocked by security gate."
    exit 1
else
    echo "✅ Pipeline completed successfully."
    exit 0
fi
