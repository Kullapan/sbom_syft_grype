#!/bin/bash
# scan-local.sh — Local directory SBOM scanner
# Scans a mounted directory at SCAN_TARGET (default: /scan-target)
# Useful for CI/CD where source is already available locally

set -e

# ─────────────────────────────────────────────────────────────────────────────
# Source shared library
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-common.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────────────────────
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║        SSDLC Pipeline — Local Directory Scanner             ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Set defaults
# Looser default mode (warning) for local scans — typically dev workstations
# ─────────────────────────────────────────────────────────────────────────────
SCAN_TARGET="${SCAN_TARGET:-/scan-target}"
GRYPE_SEVERITY="${GRYPE_SEVERITY:-critical}"
GRYPE_MODE="${GRYPE_MODE:-warning}"
REPORT_BASE_DIR="${REPORT_BASE_DIR:-/reports}"

echo "  Config:"
echo "    Scan Target:     $SCAN_TARGET"
echo "    Grype Severity:  $GRYPE_SEVERITY"
echo "    Grype Mode:      $GRYPE_MODE"
echo "    Report Dir:      $REPORT_BASE_DIR"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Validate required environment variables and scan target
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "$DTRACK_URL" ] || [ -z "$DTRACK_API_KEY" ]; then
    echo "ERROR: Missing required environment variables."
    echo "  Required: DTRACK_URL, DTRACK_API_KEY"
    exit 1
fi

if [ ! -d "$SCAN_TARGET" ]; then
    echo "ERROR: Scan target is not a valid directory: $SCAN_TARGET"
    echo "  Mount your source directory to $SCAN_TARGET or set SCAN_TARGET env var."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Derive project metadata
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "$DTRACK_PROJECT_NAME" ]; then
    # Try 1: Git remote origin URL name
    if git -C "$SCAN_TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        GIT_URL=$(git -C "$SCAN_TARGET" config --get remote.origin.url 2>/dev/null)
        if [ -n "$GIT_URL" ]; then
            DTRACK_PROJECT_NAME=$(basename "$GIT_URL" .git)
        fi
    fi

    # Try 2: package.json name field
    if [ -z "$DTRACK_PROJECT_NAME" ] && [ -f "$SCAN_TARGET/package.json" ]; then
        DTRACK_PROJECT_NAME=$(grep -o '"name": *"[^"]*"' "$SCAN_TARGET/package.json" | head -n 1 | cut -d'"' -f4)
    fi

    # Try 3: pom.xml artifactId
    if [ -z "$DTRACK_PROJECT_NAME" ] && [ -f "$SCAN_TARGET/pom.xml" ]; then
        DTRACK_PROJECT_NAME=$(grep -o '<artifactId>[^<]*</artifactId>' "$SCAN_TARGET/pom.xml" | head -n 1 | sed -e 's/<[^>]*>//g' | tr -d '[:space:]')
    fi

    # Fallback: basename of SCAN_TARGET
    if [ -z "$DTRACK_PROJECT_NAME" ]; then
        DTRACK_PROJECT_NAME=$(basename "$SCAN_TARGET")
    fi
fi

PROJECT_NAME="$DTRACK_PROJECT_NAME"
PROJECT_VERSION="${DTRACK_PROJECT_VERSION:-local-$(date +%Y%m%d)}"
OUTPUT_DIR="${REPORT_BASE_DIR}/${PROJECT_NAME}"

echo "  Project:"
echo "    Name:     $PROJECT_NAME"
echo "    Version:  $PROJECT_VERSION"
echo "    Output:   $OUTPUT_DIR"
echo ""

mkdir -p "$OUTPUT_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Initialize root index (single repo, but same format for consistency)
# ─────────────────────────────────────────────────────────────────────────────
init_root_index "$REPORT_BASE_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Syft SBOM generation
# ─────────────────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════"
echo "  [1] Scanning: $PROJECT_NAME ($PROJECT_VERSION)"
echo "═══════════════════════════════════════════════════════════════"

run_syft "$SCAN_TARGET" "$PROJECT_NAME" "$PROJECT_VERSION" "$OUTPUT_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Grype vulnerability scan
# Grype may exit non-zero (2 = threshold exceeded), so disable set -e
# ─────────────────────────────────────────────────────────────────────────────
set +e
run_grype "${OUTPUT_DIR}/sbom.json" "$GRYPE_SEVERITY" "$GRYPE_MODE" "$OUTPUT_DIR"
GRYPE_EXIT=$?
set -e

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Upload to Dependency-Track
# Non-blocking: upload failure should not stop the pipeline
# ─────────────────────────────────────────────────────────────────────────────
set +e
upload_to_dtrack "${OUTPUT_DIR}/sbom.json" "$PROJECT_NAME" "$PROJECT_VERSION"
UPLOAD_EXIT=$?
set -e

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Generate per-repo summary
# ─────────────────────────────────────────────────────────────────────────────
generate_repo_summary "$PROJECT_NAME" "local://${SCAN_TARGET}" "$PROJECT_VERSION" \
    "$OUTPUT_DIR" "$GRYPE_EXIT" "$UPLOAD_EXIT" "$DTRACK_URL"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Update root index
# ─────────────────────────────────────────────────────────────────────────────
append_root_index "1" "$PROJECT_NAME" "$PROJECT_VERSION" \
    "$OUTPUT_DIR" "$GRYPE_EXIT" "$GRYPE_MODE" "$UPLOAD_EXIT"

# Track failure for final exit code
FAILED=0
if [ "$GRYPE_MODE" = "block" ] && [ "$GRYPE_EXIT" -ne 0 ]; then
    FAILED=1
fi

finalize_root_index "$REPORT_BASE_DIR" "1" "$FAILED" "$GRYPE_MODE"

# ─────────────────────────────────────────────────────────────────────────────
# Final result
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                    Pipeline Complete                         ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
printf "║  Project: %-20s  |  Mode: %-12s       ║\n" "$PROJECT_NAME" "$GRYPE_MODE"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

if [ "$GRYPE_MODE" = "block" ] && [ "$GRYPE_EXIT" -ne 0 ]; then
    echo "🚫 Pipeline FAILED — Security gate blocked this scan."
    exit 1
elif [ "$GRYPE_MODE" = "warning" ] && [ "$GRYPE_EXIT" -ne 0 ]; then
    echo "⚠️  Pipeline completed with WARNINGS — vulnerabilities found above threshold."
    exit 0
else
    echo "✅ Pipeline completed successfully."
    exit 0
fi
