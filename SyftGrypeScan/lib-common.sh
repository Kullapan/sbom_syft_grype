#!/bin/bash
# lib-common.sh — Shared functions for SSDLC pipeline
# Sourced by scan-git.sh and scan-local.sh
# Contains: Syft, Grype, DTrack upload, report generation utilities

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# generate_gradle_sbom — Generate SBOM using CycloneDX Gradle plugin via init script
# Args: scan_dir, project_name, project_version, output_dir
# Returns: 0 on success, 1 on failure
# =============================================================================
generate_gradle_sbom() {
    local scan_dir="$1"
    local project_name="$2"
    local project_version="$3"
    local output_dir="$4"

    echo ""
    echo "  [Gradle] Gradle project detected. Generating SBOM via CycloneDX plugin..."
    local start_time
    start_time=$(date +%s)

    # Make gradlew executable
    chmod +x "${scan_dir}/gradlew" 2>/dev/null || true

    # Create temporary init.gradle script to inject the CycloneDX plugin
    cat << 'EOF' > /tmp/init.gradle
import org.cyclonedx.gradle.CyclonedxPlugin

initscript {
    repositories {
        mavenCentral()
        gradlePluginPortal()
    }
    dependencies {
        classpath 'org.cyclonedx.bom:org.cyclonedx.bom.gradle.plugin:3.2.4'
    }
}
allprojects {
    apply plugin: CyclonedxPlugin
}
EOF

    # Run the cyclonedxBom task, disabling set -e temporarily
    set +e
    (
        cd "$scan_dir"
        ./gradlew --init-script /tmp/init.gradle cyclonedxBom -x test
    )
    local gradle_exit=$?
    set -e

    rm -f /tmp/init.gradle

    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))

    # Find any generated sbom.json or bom.json in the build output directory
    local generated_bom
    generated_bom=$(find "${scan_dir}/build" -type f \( -name "sbom.json" -o -name "bom.json" \) 2>/dev/null | head -n 1)

    if [ -n "$generated_bom" ] && [ -f "$generated_bom" ]; then
        cp "$generated_bom" "${output_dir}/sbom.json"
        echo "  [Gradle] ✅ SBOM generated successfully via CycloneDX Plugin in ${elapsed}s -> ${output_dir}/sbom.json"
        return 0
    else
        echo "  [Gradle] ⚠️  CycloneDX plugin generation failed (exit: $gradle_exit) after ${elapsed}s. Falling back to Syft."
        return 1
    fi
}

# =============================================================================
# generate_maven_sbom — Generate SBOM using CycloneDX Maven plugin dynamically
# Args: scan_dir, project_name, project_version, output_dir
# Returns: 0 on success, 1 on failure
# =============================================================================
generate_maven_sbom() {
    local scan_dir="$1"
    local project_name="$2"
    local project_version="$3"
    local output_dir="$4"

    echo ""
    echo "  [Maven] Maven project detected. Generating SBOM via CycloneDX plugin..."
    local start_time
    start_time=$(date +%s)

    # Use mvnw if present, otherwise fallback to globally installed mvn
    local mvn_cmd="mvn"
    if [ -x "${scan_dir}/mvnw" ]; then
        mvn_cmd="./mvnw"
    fi

    # Run the cyclonedx plugin, disabling set -e temporarily
    set +e
    (
        cd "$scan_dir"
        $mvn_cmd org.cyclonedx:cyclonedx-maven-plugin:2.9.1:makeAggregateBom -DoutputFormat=json -DoutputName=sbom
    )
    local mvn_exit=$?
    set -e

    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))

    # Find generated sbom.json in target/ directory
    local generated_bom
    generated_bom=$(find "${scan_dir}/target" -type f -name "sbom.json" 2>/dev/null | head -n 1)
    
    # Fallback to bom.json if outputName wasn't respected
    if [ -z "$generated_bom" ]; then
        generated_bom=$(find "${scan_dir}/target" -type f -name "bom.json" 2>/dev/null | head -n 1)
    fi

    if [ -n "$generated_bom" ] && [ -f "$generated_bom" ]; then
        cp "$generated_bom" "${output_dir}/sbom.json"
        echo "  [Maven] ✅ SBOM generated successfully via CycloneDX Plugin in ${elapsed}s -> ${output_dir}/sbom.json"
        return 0
    else
        echo "  [Maven] ⚠️  CycloneDX plugin generation failed (exit: $mvn_exit) after ${elapsed}s. Falling back to Syft."
        return 1
    fi
}

# =============================================================================
# merge_sbom_files — Merge multiple CycloneDX SBOM JSON files into one
# Uses the first SBOM as a base template and appends components from others.
# Pure shell implementation (no jq dependency).
# Args: sbom_dir (directory with subdirs containing sbom.json), project_name, project_version, output_path
# =============================================================================
merge_sbom_files() {
    local sbom_dir="$1"
    local project_name="$2"
    local project_version="$3"
    local output_path="$4"

    # Collect all sbom.json files
    local sbom_files
    sbom_files=$(find "$sbom_dir" -name "sbom.json" -type f 2>/dev/null)
    local file_count
    file_count=$(echo "$sbom_files" | grep -c '.' 2>/dev/null || echo "0")

    if [ "$file_count" -eq 0 ]; then
        echo "  [Merge] No SBOM files found to merge"
        return 1
    fi

    if [ "$file_count" -eq 1 ]; then
        # Only one file, just copy it
        cp "$sbom_files" "$output_path"
        echo "  [Merge] Single module SBOM copied"
        return 0
    fi

    # For multi-file merge: use the first as base, extract components from others
    local base_file
    base_file=$(echo "$sbom_files" | head -n 1)

    # Start with the base file content
    cp "$base_file" "$output_path"

    # For each additional SBOM, extract its components array content and append
    # Strategy: extract the "components" array from each additional file
    # and insert them into the base file's components array
    local additional_files
    additional_files=$(echo "$sbom_files" | tail -n +2)

    local all_extra_components=""
    while IFS= read -r sfile; do
        [ -z "$sfile" ] && continue
        # Extract the components section — content between "components":[ and the matching ]
        # Since CycloneDX JSON may be minified, use sed to extract
        local comps
        comps=$(sed -n 's/.*"components":\[\(.*\)\],.*/\1/p' "$sfile" 2>/dev/null)
        if [ -z "$comps" ]; then
            # Try without trailing comma (components might be last field)
            comps=$(sed -n 's/.*"components":\[\(.*\)\]}.*/\1/p' "$sfile" 2>/dev/null)
        fi
        if [ -n "$comps" ]; then
            if [ -n "$all_extra_components" ]; then
                all_extra_components="${all_extra_components},${comps}"
            else
                all_extra_components="$comps"
            fi
        fi
    done <<< "$additional_files"

    if [ -n "$all_extra_components" ]; then
        # Append extra components to the base file's components array
        # Replace the closing ] of components with ,extra_components]
        sed -i "s/\"components\":\[\(.*\)\]/\"components\":[\1,${all_extra_components}]/" "$output_path" 2>/dev/null || true
    fi

    echo "  [Merge] Merged $file_count module SBOMs into one"
    return 0
}

# =============================================================================
# detect_sub_projects — Detect sub-projects in a monorepo
# Scans immediate sub-directories for build manifest files.
# Outputs lines to stdout: "<subdir_name> <type>" where type is gradle|node|maven|unknown
# Args: scan_dir
# Returns: 0 if sub-projects found, 1 if none (single project)
# =============================================================================
detect_sub_projects() {
    local scan_dir="$1"
    local found=0

    for subdir in "${scan_dir}"/*/; do
        [ ! -d "$subdir" ] && continue
        local name
        name=$(basename "$subdir")

        # Skip hidden dirs and common non-project dirs
        case "$name" in
            .*|node_modules|build|dist|target|.git|.gradle) continue ;;
        esac

        local type=""
        if [ -f "${subdir}/gradlew" ] || [ -f "${subdir}/build.gradle" ] || [ -f "${subdir}/build.gradle.kts" ]; then
            type="gradle"
        elif [ -f "${subdir}/package.json" ]; then
            type="node"
        elif [ -f "${subdir}/pom.xml" ]; then
            type="maven"
        elif [ -f "${subdir}/requirements.txt" ] || [ -f "${subdir}/pyproject.toml" ]; then
            type="python"
        elif [ -f "${subdir}/go.mod" ]; then
            type="go"
        fi

        if [ -n "$type" ]; then
            echo "${name} ${type}"
            found=$((found + 1))
        fi
    done

    [ "$found" -ge 2 ] && return 0
    return 1
}

# =============================================================================
# run_syft — Generate SBOM with Syft
# Args: scan_dir, project_name, project_version, output_dir
# =============================================================================
run_syft() {
    local scan_dir="$1"
    local project_name="$2"
    local project_version="$3"
    local output_dir="$4"

    # Auto-detect Gradle wrapper — search root and sub-directories (depth 2)
    local gradlew_list
    gradlew_list=$(find "$scan_dir" -maxdepth 2 -name "gradlew" -type f 2>/dev/null)

    if [ -n "$gradlew_list" ]; then
        local gradle_dirs=()
        local seen_dirs=""

        # Deduplicate by parent directory
        while IFS= read -r gw; do
            local gw_dir
            gw_dir=$(dirname "$gw")
            # Skip if we already have this directory
            case "$seen_dirs" in
                *"|${gw_dir}|"*) continue ;;
            esac
            seen_dirs="${seen_dirs}|${gw_dir}|"
            gradle_dirs+=("$gw_dir")
        done <<< "$gradlew_list"

        local gradle_count=${#gradle_dirs[@]}

        if [ "$gradle_count" -eq 1 ]; then
            # Single Gradle project (root or single sub-dir)
            set +e
            generate_gradle_sbom "${gradle_dirs[0]}" "$project_name" "$project_version" "$output_dir"
            local gradle_success=$?
            set -e
            if [ $gradle_success -eq 0 ]; then
                return 0
            fi
        elif [ "$gradle_count" -gt 1 ]; then
            # Multi-module: scan each sub-project and merge SBOMs
            echo ""
            echo "  [Gradle] Multi-module project detected ($gradle_count modules)"
            local tmp_sbom_dir
            tmp_sbom_dir=$(mktemp -d)
            local module_success=0
            local module_idx=0

            for gdir in "${gradle_dirs[@]}"; do
                module_idx=$((module_idx + 1))
                local module_name
                module_name=$(basename "$gdir")
                echo "  [Gradle] Scanning module $module_idx/$gradle_count: $module_name"

                local module_out="${tmp_sbom_dir}/${module_name}"
                mkdir -p "$module_out"

                set +e
                generate_gradle_sbom "$gdir" "${project_name}-${module_name}" "$project_version" "$module_out"
                local ms=$?
                set -e

                if [ $ms -eq 0 ]; then
                    module_success=$((module_success + 1))
                fi
            done

            if [ $module_success -gt 0 ]; then
                # Merge all module SBOMs into one
                merge_sbom_files "$tmp_sbom_dir" "$project_name" "$project_version" "${output_dir}/sbom.json"
                rm -rf "$tmp_sbom_dir"
                echo "  [Gradle] ✅ Merged $module_success module SBOM(s) -> ${output_dir}/sbom.json"
                return 0
            fi

            rm -rf "$tmp_sbom_dir"
            echo "  [Gradle] ⚠️  All modules failed. Falling back to Syft."
        fi
    fi

    # Auto-detect Maven project and use CycloneDX plugin if available
    local pom_list
    pom_list=$(find "$scan_dir" -maxdepth 2 -name "pom.xml" -type f 2>/dev/null)
    if [ -n "$pom_list" ]; then
        # For simplicity, if we detect Maven, we run the plugin at the root of the detected scan_dir
        set +e
        generate_maven_sbom "$scan_dir" "$project_name" "$project_version" "$output_dir"
        local maven_success=$?
        set -e
        if [ $maven_success -eq 0 ]; then
            return 0
        fi
    fi

    echo ""
    echo "  [Syft] Generating SBOM for: $project_name ($project_version)"
    local start_time
    start_time=$(date +%s)

    syft "dir:${scan_dir}" \
        --source-name "$project_name" \
        --source-version "$project_version" \
        --exclude "./.git" \
        -o "cyclonedx-json@1.5=${output_dir}/sbom.json"

    local syft_exit=$?
    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))

    if [ $syft_exit -ne 0 ]; then
        echo "  [Syft] ERROR: Syft exited with code $syft_exit after ${elapsed}s"
        return $syft_exit
    fi

    echo "  [Syft] SBOM generated successfully in ${elapsed}s -> ${output_dir}/sbom.json"
    return 0
}


# =============================================================================
# run_grype — Scan SBOM for vulnerabilities
# Args: sbom_path, severity, mode, output_dir
# Returns: grype exit code (0=clean, 1=error, 2=threshold exceeded)
# =============================================================================
run_grype() {
    local sbom_path="$1"
    local severity="$2"
    local mode="$3"
    local output_dir="$4"

    echo ""
    echo "  [Grype] Scanning vulnerabilities (severity: $severity, mode: $mode)"
    local start_time
    start_time=$(date +%s)

    # Run grype with both Markdown and JSON outputs
    # Since grype does not support multiple output files/formats in a single execution,
    # we run it twice:
    # Run 1: Generate JSON output and capture the exit code (incorporates threshold check)
    grype "sbom:${sbom_path}" \
         --fail-on "$severity" \
         -o json --file "${output_dir}/grype-report.json"
    local grype_exit=$?

    # 2. Generate Markdown report using the template
    grype "sbom:${sbom_path}" \
         -o template -t "${SCRIPT_DIR}/grype-markdown.tmpl" --file "${output_dir}/grype-report.md"

    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))

    if [ $grype_exit -eq 1 ]; then
        echo "  [Grype] ERROR: Grype encountered an error (exit code 1) after ${elapsed}s"
    elif [ $grype_exit -eq 2 ]; then
        echo "  [Grype] Threshold exceeded (exit code 2) after ${elapsed}s"
    else
        echo "  [Grype] Scan completed cleanly in ${elapsed}s"
    fi

    # Apply threshold logic based on mode
    apply_grype_threshold "$grype_exit" "$mode" "$(basename "$output_dir")"

    return $grype_exit
}

# =============================================================================
# apply_grype_threshold — Handle grype result based on pipeline mode
# Args: exit_code, mode, repo_name
# Modes: info (always pass), warning (warn but pass), block (fail pipeline)
# =============================================================================
apply_grype_threshold() {
    local exit_code="$1"
    local mode="$2"
    local repo_name="$3"

    case "$mode" in
        info)
            echo "  [Grype] Mode=info — Vulnerability scan completed (informational only)"
            return 0
            ;;
        warning)
            if [ "$exit_code" -ne 0 ]; then
                printf "\n"
                printf "  ⚠️  ============================================================\n"
                printf "  ⚠️  WARNING: Vulnerabilities found exceeding threshold for: %s\n" "$repo_name"
                printf "  ⚠️  Mode=warning — Pipeline will continue despite findings\n"
                printf "  ⚠️  ============================================================\n"
                printf "\n"
            fi
            return 0
            ;;
        block)
            if [ "$exit_code" -ne 0 ]; then
                printf "\n"
                printf "  🚫 ============================================================\n"
                printf "  🚫 BLOCKED: Vulnerabilities exceed threshold for: %s\n" "$repo_name"
                printf "  🚫 Mode=block — This repo has FAILED the security gate\n"
                printf "  🚫 ============================================================\n"
                printf "\n"
                return 1
            fi
            return 0
            ;;
        *)
            echo "  [Grype] Unknown mode '$mode', treating as 'block'"
            if [ "$exit_code" -ne 0 ]; then
                return 1
            fi
            return 0
            ;;
    esac
}

# =============================================================================
# upload_to_dtrack — Upload SBOM to OWASP Dependency-Track
# NON-BLOCKING: never calls exit, always returns
# Args: sbom_path, project_name, project_version
# Returns: 0 on success, 1 on failure
# =============================================================================
upload_to_dtrack() {
    local sbom_path="$1"
    local project_name="$2"
    local project_version="$3"

    echo ""
    echo "  [DTrack] Uploading SBOM: $project_name ($project_version)"

    if [ -z "$DTRACK_URL" ] || [ -z "$DTRACK_API_KEY" ]; then
        echo "  [DTrack] ⚠️  Skipped — DTRACK_URL or DTRACK_API_KEY not set"
        return 1
    fi

    if [ ! -f "$sbom_path" ]; then
        echo "  [DTrack] ⚠️  Error — SBOM file not found: $sbom_path"
        return 1
    fi

    # Capture both HTTP body and status code
    local tmp_response
    tmp_response=$(mktemp)

    set +e
    local http_code
    http_code=$(curl -s -w "%{http_code}" \
        --max-time 60 \
        --retry 2 \
        -X "POST" "${DTRACK_URL}/api/v1/bom" \
        -H "X-Api-Key: ${DTRACK_API_KEY}" \
        -H "Content-Type: multipart/form-data" \
        -F "autoCreate=true" \
        -F "projectName=${project_name}" \
        -F "projectVersion=${project_version}" \
        -F "bom=@${sbom_path}" \
        -o "$tmp_response")
    local curl_exit=$?
    set -e

    local response_body
    response_body=$(cat "$tmp_response" 2>/dev/null || echo "")
    rm -f "$tmp_response"

    # Check for curl-level failure (network error, timeout, etc.)
    if [ $curl_exit -ne 0 ]; then
        printf "  [DTrack] ⚠️  Upload FAILED — curl error (exit code: %d)\n" "$curl_exit"
        printf "  [DTrack]     URL: %s/api/v1/bom\n" "$DTRACK_URL"
        printf "  [DTrack]     Project: %s (%s)\n" "$project_name" "$project_version"
        return 1
    fi

    # Check HTTP status code
    if [ "$http_code" != "200" ]; then
        printf "  [DTrack] ⚠️  Upload FAILED — HTTP %s\n" "$http_code"
        printf "  [DTrack]     Response: %s\n" "$response_body"
        return 1
    fi

    # Extract token from response for reference
    local token
    token=$(echo "$response_body" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -n "$token" ]; then
        printf "  [DTrack] ✅ Upload successful (token: %s)\n" "$token"
    else
        printf "  [DTrack] ✅ Upload successful (HTTP 200)\n"
    fi

    return 0
}

# =============================================================================
# count_severity — Count vulnerabilities of a specific severity in grype JSON
# Args: grype_json_path, severity_level (Critical|High|Medium|Low)
# Outputs: integer count to stdout
# Uses grep to avoid jq dependency
# =============================================================================
count_severity() {
    local grype_json="$1"
    local severity="$2"

    if [ ! -f "$grype_json" ]; then
        echo "0"
        return
    fi

    # Match "severity":"Critical" (case-sensitive, exact field match)
    # Using grep -o | wc -l because JSON outputs may be single-line (minified)
    local count
    count=$(grep -o "\"severity\":\"${severity}\"" "$grype_json" 2>/dev/null | wc -l || echo "0")
    echo "$count" | tr -d '[:space:]'
}

# =============================================================================
# count_sbom_components — Count components in CycloneDX SBOM JSON
# Args: sbom_json_path
# Outputs: integer count to stdout
# =============================================================================
count_sbom_components() {
    local sbom_json="$1"

    if [ ! -f "$sbom_json" ]; then
        echo "0"
        return
    fi

    # Count "bom-ref" fields — each component has one
    # Using grep -o | wc -l because JSON outputs may be single-line (minified)
    local count
    count=$(grep -o '"bom-ref"' "$sbom_json" 2>/dev/null | wc -l || echo "0")
    
    # Subtract 1 to exclude the root metadata component's own bom-ref
    if [ "$count" -gt 0 ]; then
        count=$((count - 1))
    fi
    echo "$count" | tr -d '[:space:]'
}

# =============================================================================
# init_root_index — Create the pipeline summary index header
# Args: report_base_dir
# =============================================================================
init_root_index() {
    local report_base_dir="$1"
    local index_file="${report_base_dir}/pipeline-summary.md"

    mkdir -p "$report_base_dir"

    cat > "$index_file" <<EOF
# 📋 SSDLC Pipeline Run — Index
**Run Date:** $(date)  |  **Grype Mode:** ${GRYPE_MODE}  |  **Severity:** ${GRYPE_SEVERITY}

| # | Repo | Branch | Critical | High | Medium | Low | Grype Result | DTrack Upload | Detail |
| :---: | :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
EOF

    echo "  [Index] Root index initialized: $index_file"
}

# =============================================================================
# append_root_index — Add one repo row to the pipeline summary
# Args: index_counter, project_name, branch, output_dir, grype_exit, grype_mode, upload_exit
# =============================================================================
append_root_index() {
    local index_counter="$1"
    local project_name="$2"
    local branch="$3"
    local output_dir="$4"
    local grype_exit="$5"
    local grype_mode="$6"
    local upload_exit="$7"

    local report_base_dir
    report_base_dir=$(dirname "$output_dir")
    local index_file="${report_base_dir}/pipeline-summary.md"

    # Count severities from grype JSON
    local critical high medium low
    critical=$(count_severity "${output_dir}/grype-report.json" "Critical")
    high=$(count_severity "${output_dir}/grype-report.json" "High")
    medium=$(count_severity "${output_dir}/grype-report.json" "Medium")
    low=$(count_severity "${output_dir}/grype-report.json" "Low")

    # Determine grype result text based on mode and exit code
    local grype_result
    if [ "$grype_exit" -eq 0 ]; then
        grype_result="✅ PASS"
    else
        case "$grype_mode" in
            info)    grype_result="✅ PASS" ;;
            warning) grype_result="⚠️ WARN" ;;
            block)   grype_result="🚫 BLOCK" ;;
            *)       grype_result="🚫 BLOCK" ;;
        esac
    fi

    # Determine upload result text
    local upload_result
    if [ "$upload_exit" -eq 0 ]; then
        upload_result="✅ Uploaded"
    else
        upload_result="❌ Failed"
    fi

    # Relative link to per-repo summary
    local detail_link="[📄 Report](./${project_name}/pipeline-summary.md)"

    # Append row to index
    printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" \
        "$index_counter" "$project_name" "$branch" \
        "$critical" "$high" "$medium" "$low" \
        "$grype_result" "$upload_result" "$detail_link" \
        >> "$index_file"
}

# =============================================================================
# finalize_root_index — Append footer to pipeline summary
# Args: report_base_dir, total, failed, grype_mode
# =============================================================================
finalize_root_index() {
    local report_base_dir="$1"
    local total="$2"
    local failed="$3"
    local grype_mode="$4"

    local index_file="${report_base_dir}/pipeline-summary.md"

    printf "\n**Total Repos:** %s  |  **Failed:** %s\n" "$total" "$failed" >> "$index_file"

    # Overall result
    if [ "$failed" -eq 0 ]; then
        printf "\n✅ **Overall Result: PASSED** — All repos cleared the security gate.\n" >> "$index_file"
    else
        case "$grype_mode" in
            info)
                printf "\n✅ **Overall Result: PASSED** — Mode=info, findings are informational only.\n" >> "$index_file"
                ;;
            warning)
                printf "\n⚠️  **Overall Result: PASSED WITH WARNINGS** — %s repo(s) had findings above threshold.\n" "$failed" >> "$index_file"
                ;;
            block)
                printf "\n🚫 **Overall Result: FAILED** — %s repo(s) BLOCKED by security gate.\n" "$failed" >> "$index_file"
                ;;
        esac
    fi

    echo "  [Index] Root index finalized: $index_file"
}

# =============================================================================
# generate_repo_summary — Create per-repo pipeline-summary.md
# Args: project_name, repo_url, branch, output_dir, grype_exit, upload_exit, dtrack_url
# =============================================================================
generate_repo_summary() {
    local project_name="$1"
    local repo_url="$2"
    local branch="$3"
    local output_dir="$4"
    local grype_exit="$5"
    local upload_exit="$6"
    local dtrack_url="$7"

    local summary_file="${output_dir}/pipeline-summary.md"

    # Get tool versions
    local syft_ver grype_ver
    syft_ver=$(syft --version 2>/dev/null || echo "unknown")
    grype_ver=$(grype --version 2>/dev/null || echo "unknown")

    # Count SBOM components
    local component_count
    component_count=$(count_sbom_components "${output_dir}/sbom.json")

    # Count severities
    local critical high medium low
    critical=$(count_severity "${output_dir}/grype-report.json" "Critical")
    high=$(count_severity "${output_dir}/grype-report.json" "High")
    medium=$(count_severity "${output_dir}/grype-report.json" "Medium")
    low=$(count_severity "${output_dir}/grype-report.json" "Low")

    # Determine threshold result
    local threshold_result threshold_detail
    if [ "$grype_exit" -eq 0 ]; then
        threshold_result="✅ PASSED"
        threshold_detail="No vulnerabilities found at or above **${GRYPE_SEVERITY}** severity."
    else
        case "$GRYPE_MODE" in
            info)
                threshold_result="✅ PASSED (info mode)"
                threshold_detail="Vulnerabilities found above **${GRYPE_SEVERITY}**, but mode=info — informational only."
                ;;
            warning)
                threshold_result="⚠️ WARNING"
                threshold_detail="Vulnerabilities found above **${GRYPE_SEVERITY}** threshold. Mode=warning — pipeline continues."
                ;;
            block)
                threshold_result="🚫 BLOCKED"
                threshold_detail="Vulnerabilities found above **${GRYPE_SEVERITY}** threshold. Mode=block — pipeline FAILED for this repo."
                ;;
        esac
    fi

    # Determine upload status
    local upload_status upload_detail
    if [ "$upload_exit" -eq 0 ]; then
        upload_status="✅ Uploaded Successfully"
        upload_detail="SBOM uploaded to Dependency-Track at ${dtrack_url}"
    else
        upload_status="❌ Upload Failed"
        upload_detail="SBOM upload to Dependency-Track failed. Check logs for details."
    fi

    # Write the summary
    cat > "$summary_file" <<EOF
# 📊 Pipeline Report — ${project_name}

## Scan Metadata

| Field | Value |
| :--- | :--- |
| **Repository** | ${repo_url} |
| **Branch** | ${branch} |
| **Scan Date** | $(date) |
| **Syft Version** | ${syft_ver} |
| **Grype Version** | ${grype_ver} |
| **Grype Severity** | ${GRYPE_SEVERITY} |
| **Grype Mode** | ${GRYPE_MODE} |

## SBOM Summary

- **Total Components:** ${component_count}
- **Format:** CycloneDX JSON v1.5
- **File:** [sbom.json](./sbom.json)

## Vulnerability Summary

| Severity | Count |
| :--- | :---: |
| 🔴 Critical | ${critical} |
| 🟠 High | ${high} |
| 🟡 Medium | ${medium} |
| 🔵 Low | ${low} |

## Threshold Result

**${threshold_result}**

${threshold_detail}

## Dependency-Track Upload

**${upload_status}**

${upload_detail}

## Report Files

- [📝 Grype Report (Markdown)](./grype-report.md)
- [📦 Grype Report (JSON)](./grype-report.json)
- [📋 SBOM (CycloneDX JSON)](./sbom.json)
EOF

    echo "  [Report] Per-repo summary generated: $summary_file"
}
