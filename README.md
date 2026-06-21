# SSDLC + SBOM Pipeline

## Overview

Automated **Software Bill of Materials (SBOM)** generation and vulnerability scanning pipeline for the Antigravity Project. The pipeline scans source code repositories (or local directories), produces machine-readable SBOMs, runs vulnerability analysis, and uploads results to a central dashboard.

| Component | Version | Role |
|---|---|---|
| **Syft** | v1.44.0 | SBOM generation (CycloneDX JSON 1.5) |
| **Grype** | v0.114.0 | Vulnerability scanning — Markdown + JSON reports |
| **OWASP Dependency-Track** | v5.x | SBOM management and risk dashboard |
| **PostgreSQL** | 16 | Dependency-Track persistent database |

---

## Architecture

The scanner image ships **two entrypoint scripts** plus a shared library:

```
┌──────────────────────────────────────────────────┐
│              sbom-scanner container               │
│                                                  │
│  ┌──────────────┐  ┌──────────────┐              │
│  │ scan-git.sh  │  │ scan-local.sh│              │
│  │  (multi-repo │  │ (single dir) │              │
│  │   git scan)  │  │              │              │
│  └──────┬───────┘  └──────┬───────┘              │
│         │                 │                      │
│         ▼                 ▼                      │
│  ┌──────────────────────────────┐                │
│  │       lib-common.sh          │                │
│  │  • run_syft()                │                │
│  │  • run_grype()               │                │
│  │  • upload_to_dtrack()        │                │
│  │  • generate_summary()        │                │
│  └──────────────────────────────┘                │
│         │                                        │
│         ▼                                        │
│  ┌──────────────────────────────┐                │
│  │   Syft → CycloneDX JSON     │                │
│  │   Grype → Markdown + JSON   │──▶ /reports    │
│  │   DTrack upload (async)      │                │
│  └──────────────────────────────┘                │
└──────────────────────────────────────────────────┘
         │ non-blocking upload
         ▼
┌──────────────────────┐     ┌──────────────┐
│ Dependency-Track API │◀───▶│ PostgreSQL   │
│  :8080 (API)         │     │  :5432       │
│  :8081 (Frontend)    │     └──────────────┘
└──────────────────────┘
```

### scan-git.sh — Multi-Repo Git Scanner

Supports **3 input modes** (evaluated in priority order):

1. **Repos file** — `GIT_REPOS_FILE` points to a text file listing one repo URL per line (with optional `branch` and `project-name` fields).
2. **Env list** — `GIT_REPOS` contains a comma-separated list of repo URLs.
3. **Single URL** — `GIT_REPO_URL` (+ optional `GIT_BRANCH`) scans exactly one repository.

Each repo is shallow-cloned (`git clone --depth 1`), scanned, reported, and then cleaned up.

### scan-local.sh — Local Directory Scanner

Mounts a host directory at `/scan-target` (read-only) and scans it in place. Useful for CI/CD stages where the source is already checked out.

### lib-common.sh — Shared Functions

Common logic shared by both scanners:

- `run_syft()` — Generate CycloneDX JSON 1.5 SBOM
- `run_grype()` — Vulnerability scan with severity threshold
- `upload_to_dtrack()` — Non-blocking BOM upload via REST API
- `generate_summary()` — Pipeline summary in Markdown
- Logging, error handling, and exit-code management

---

## Prerequisites

- **Docker** ≥ 24.x + **Docker Compose** v2
- **Git** (for local development / manual runs)
- Network access to:
  - Target Git repositories
  - Container registries (`docker.io`, `ghcr.io`)
  - Anchore install scripts (`raw.githubusercontent.com`)

---

## Quick Start

### 1. Start Dependency-Track Stack

```bash
cp .env.example .env
# Edit .env with your settings (ports, passwords, etc.)
docker compose up -d postgres dtrack-apiserver dtrack-frontend
```

Wait approximately **60 seconds** for first-boot initialisation, then:

1. Open **http://localhost:8081**
2. Login with default credentials: `admin` / `admin`
3. Navigate to **Administration → Access Management → Teams → Automation**
4. Copy the **API Key**
5. Update `DTRACK_API_KEY` in your `.env` file

### 2. Build Scanner Image

```bash
docker build -t sbom-scanner ./SyftGrypeScan
# or use docker compose:
docker compose build git-scanner
```

### 3a. Scan Git Repos (Multi-Repo via File)

You can scan multiple repositories in one go by providing a list in a text file.

```bash
# Create your repos list from the example
cp SyftGrypeScan/repos.example.txt SyftGrypeScan/repos.txt

# Edit SyftGrypeScan/repos.txt — one repo per line:
#   https://github.com/org/repo.git  main  my-project-name
#   https://github.com/org/other.git
```

**Method A: Using raw Docker command (with `.env` file)**
```bash
docker run --rm \
  --network sbom_dtrack-net \
  -v "%cd%/SyftGrypeScan/repos.txt:/repos-config/repos.txt:ro" \
  -v "%cd%/reports:/reports" \
  --env-file .env \
  sbom-scanner /app/scan-git.sh
```

**Method B: Using Docker Compose**
```bash
docker compose --profile scanner run --rm git-scanner
```

### 3b. Scan Git Repos (Single Repo via ENV)

```bash
docker run --rm \
  --network sbom_dtrack-net \
  -v "$(pwd)/reports:/reports" \
  -e GIT_REPO_URL=https://github.com/WebGoat/WebGoat.git \
  -e GIT_BRANCH=main \
  -e GRYPE_SEVERITY=high \
  -e GRYPE_MODE=warning \
  -e DTRACK_URL=http://dtrack-apiserver:8080 \
  -e DTRACK_API_KEY=your-api-key-here \
  sbom-scanner /app/scan-git.sh
```

### 3c. Scan Local Directory (Local Test Run)

Use this method to test the scanner against a local project on your machine without cloning from Git. The container mounts your local directory (read-only) and performs the full scan pipeline.

```bash
# 1. CD into the SBOM pipeline folder
cd C:\KK\Workspace\AntigravityProject\SBOM

# 2. Run the scanner against your local project folder (e.g. ../my-app)
docker run --rm \
  --network sbom_dtrack-net \
  -v "C:\KK\Workspace\AntigravityProject\my-app:/scan-target:ro" \
  -v "%cd%/reports:/reports" \
  --env-file .env \
  sbom-scanner /app/scan-local.sh
```

*(Note: Using `--env-file .env` automatically loads your `DTRACK_URL`, `DTRACK_API_KEY`, and Grype configuration so you don't have to pass `-e` arguments manually.)*

---

## 🌟 Advanced Capabilities

### High-Fidelity SBOMs (Dynamic Plugins)

Standard Syft scanning is excellent but sometimes struggles to resolve deep dependencies in Java projects without executing the build tool. The scanner features **Dynamic Plugin Injection**:
- **Gradle**: Automatically detects `gradlew`, injects a temporary `init.gradle` with the CycloneDX plugin (v3.x), and executes `cyclonedxBom` to resolve high-fidelity dependencies.
- **Maven**: Automatically detects `pom.xml`, locates `mvnw` (or uses the globally installed `mvn`), and executes `org.cyclonedx:cyclonedx-maven-plugin` to generate an aggregate BOM.
- **Fallback**: If the build task fails or is not applicable, the scanner seamlessly falls back to standard Syft analysis.

**Benefit:** Developers do not need to modify their `build.gradle` or `pom.xml` to support the SSDLC pipeline.

### Monorepo & Multi-Module Support

The scanner automatically handles complex repository structures:
- **Monorepos (Frontend + Backend):** Detects independent sub-projects (e.g., a Node.js `frontend/` and a Gradle `backend/`). It scans each independently and uploads them to Dependency-Track as separate projects (e.g., `myrepo-frontend` and `myrepo-backend`).
- **Multi-Module Projects:** For deeply nested modules (e.g., multiple Gradle subprojects), it generates an individual SBOM per module and merges them into a single comprehensive SBOM prior to vulnerability scanning and uploading.

---

## Environment Variables Reference

| Variable | Required | Default | Description |
|---|---|---|---|
| `DTRACK_URL` | **Yes** | — | Dependency-Track API server URL (e.g. `http://dtrack-apiserver:8080`) |
| `DTRACK_API_KEY` | **Yes** | — | API key for Dependency-Track (Automation team) |
| `GRYPE_SEVERITY` | No | `medium` | Minimum severity threshold: `negligible`, `low`, `medium`, `high`, `critical` |
| `GRYPE_MODE` | No | `warning` | Threshold behaviour: `info`, `warning`, `block` (see below) |
| `GIT_REPOS_FILE` | No | `/repos-config/repos.txt` | Path (inside container) to repos list file |
| `GIT_REPOS` | No | — | Comma-separated list of Git repo URLs |
| `GIT_REPO_URL` | No | — | Single Git repository URL to scan |
| `GIT_BRANCH` | No | `main` | Branch to clone (used with `GIT_REPO_URL`) |
| `SCAN_TARGET` | No | `/scan-target` | Path (inside container) to local scan directory |
| `DTRACK_PROJECT_NAME` | No | *(derived from repo)* | Override project name for DTrack upload |
| `DTRACK_PROJECT_VERSION` | No | `latest` | Project version tag for DTrack upload |
| `LOCAL_SCAN_PATH` | No | `./` | Host path mounted into `/scan-target` (docker-compose) |
| `GIT_REPOS_FILE_HOST` | No | `./SyftGrypeScan/repos.txt` | Host path to repos file (docker-compose) |
| `REPORT_BASE_DIR` | No | `/reports` | Base directory for all generated reports |

---

## Grype Threshold Modes

The `GRYPE_MODE` variable controls how the pipeline reacts when vulnerabilities at or above `GRYPE_SEVERITY` are found:

### `info` — Log Only

```
GRYPE_MODE=info  GRYPE_SEVERITY=high
```

Vulnerabilities are logged to the report but the pipeline **always exits 0**. Use this for visibility-only scans during early adoption.

### `warning` — Warn Banner

```
GRYPE_MODE=warning  GRYPE_SEVERITY=high
```

A prominent `⚠ WARNING` banner is printed to the console and included in the summary report. The pipeline **still exits 0**. Use this in pre-production pipelines to surface risk without blocking deployments.

### `block` — Fail Pipeline

```
GRYPE_MODE=block  GRYPE_SEVERITY=critical
```

If any vulnerability meets or exceeds the threshold, the pipeline **exits non-zero** (exit code 2). Use this in production CI/CD gates to enforce security policies.

---

## Report Output Structure

All reports are written to `/reports` (mounted from the host). A timestamped root directory is created per run:

```
reports/
└── 2026-06-21_100000/
    ├── pipeline-summary.md            # Roll-up summary for all scanned repos
    ├── WebGoat/
    │   ├── sbom-cyclonedx.json        # CycloneDX 1.5 JSON SBOM
    │   ├── grype-results.json         # Raw Grype JSON output
    │   ├── grype-report.md            # Human-readable Markdown report
    │   └── dtrack-upload.log          # Upload response / errors
    ├── juice-shop/
    │   ├── sbom-cyclonedx.json
    │   ├── grype-results.json
    │   ├── grype-report.md
    │   └── dtrack-upload.log
    └── ...
```

Each repo gets its own subdirectory. The root `pipeline-summary.md` contains:

- Scan timestamp and duration
- Per-repo vulnerability counts by severity
- Grype threshold result (PASS / WARN / BLOCK)
- DTrack upload status (OK / FAILED / SKIPPED)

---

## DTrack Upload Behaviour

- **Non-blocking** — Upload failure **never** stops the pipeline. The scan completes and reports are always written to disk.
- Errors are logged to `dtrack-upload.log` per repo and reflected in `pipeline-summary.md`.
- Upload uses `autoCreate=true` — projects that don't exist in Dependency-Track are **automatically created** on first upload.
- The uploaded BOM format is CycloneDX JSON 1.5.

---

## Remote Safety

The pipeline is designed for **read-only** interaction with remote repositories:

- Only `git clone --depth 1` is used — shallow, single-branch clone
- **No** `git push`, `git commit`, or `git add` is ever executed
- The cloned workspace is **deleted** immediately after the Syft scan completes
- All operations run inside an ephemeral container — nothing persists beyond `/reports`

---

## OpenShift (Future)

Phase 2 will migrate the pipeline to run on OpenShift:

- **CronJob** resources for scheduled multi-repo scans
- **BuildConfig** to build the scanner image in-cluster
- **NetworkPolicy** for DTrack API access control
- **PersistentVolumeClaim** for report storage
- Helm chart or Kustomize overlays for environment-specific configuration
- Integration with OpenShift Pipelines (Tekton) for CI/CD triggers

---

## File Structure

```
SBOM/
├── README.md                          # This file
├── .env.example                       # Environment variable template
├── docker-compose.yml                 # Full stack: DTrack + PostgreSQL + scanners
├── SyftGrypeScan/
│   ├── Dockerfile                     # Scanner image definition
│   ├── lib-common.sh                  # Shared functions (Syft, Grype, DTrack upload)
│   ├── scan-git.sh                    # Multi-repo Git scanner entrypoint
│   ├── scan-local.sh                  # Local directory scanner entrypoint
│   ├── grype-markdown.tmpl            # Go template for Grype Markdown reports
│   ├── repos.example.txt              # Example repos list file
│   └── repos.txt                      # Your repos list (git-ignored)
└── reports/                           # Generated reports (git-ignored)
    └── <timestamp>/
        ├── pipeline-summary.md
        └── <repo-name>/
            ├── sbom-cyclonedx.json
            ├── grype-results.json
            ├── grype-report.md
            └── dtrack-upload.log
```

---

## License

Internal use — Antigravity Project.
