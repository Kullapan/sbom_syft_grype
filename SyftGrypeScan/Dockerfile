# ============================================================
# SSDLC + SBOM Pipeline Scanner
# Tools: Syft v1.44.0 + Grype v0.114.0
# Usage:
#   docker build -t sbom-scanner ./SyftGrypeScan
#   docker run ... sbom-scanner /app/scan-git.sh    (git repos)
#   docker run ... sbom-scanner /app/scan-local.sh  (local dir)
# ============================================================

FROM alpine:3.19

# Install system dependencies
RUN apk add --no-cache git curl bash openjdk21 maven

# Install Syft v1.44.0
RUN curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
    | sh -s -- -b /usr/local/bin v1.44.0

# Install Grype v0.114.0
RUN curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh \
    | sh -s -- -b /usr/local/bin v0.114.0

# Setup working directories
WORKDIR /app
RUN mkdir -p /reports /scan-target /repos-config

# Copy pipeline scripts
COPY lib-common.sh        /app/lib-common.sh
COPY scan-git.sh           /app/scan-git.sh
COPY scan-local.sh         /app/scan-local.sh
COPY grype-markdown.tmpl   /app/grype-markdown.tmpl
COPY repos.example.txt     /app/repos.example.txt

# Make scripts executable
RUN chmod +x /app/lib-common.sh /app/scan-git.sh /app/scan-local.sh

# Declare volumes for reports and scan targets
VOLUME ["/reports", "/scan-target", "/repos-config"]

# Default: git scan (override with /app/scan-local.sh)
ENTRYPOINT ["/bin/bash"]
CMD ["/app/scan-git.sh"]