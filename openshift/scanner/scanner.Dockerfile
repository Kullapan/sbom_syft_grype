# ============================================================
# SSDLC + SBOM Pipeline Scanner (OpenShift Edition)
# Tools: Syft v1.44.0 + Grype v0.114.0
# Built specifically for OpenShift to run as non-root.
# ============================================================

FROM alpine:3.19

# Install system dependencies
RUN apk add --no-cache git curl bash openjdk21 maven shadow

# Add a non-root user (UID 1001) for OpenShift
RUN useradd -m -u 1001 -s /bin/bash scanner

# Install Syft v1.44.0
RUN curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
    | sh -s -- -b /usr/local/bin v1.44.0

# Install Grype v0.114.0
RUN curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh \
    | sh -s -- -b /usr/local/bin v0.114.0

# Setup working directories
WORKDIR /app
RUN mkdir -p /reports /scan-target /repos-config && \
    chown -R 1001:0 /app /reports /scan-target /repos-config && \
    chmod -R g+rwX /app /reports /scan-target /repos-config

# Switch to non-root user
USER 1001

# Copy pipeline scripts (assuming BuildConfig contextDir is the root of the repo)
COPY --chown=1001:0 SyftGrypeScan/lib-common.sh        /app/lib-common.sh
COPY --chown=1001:0 SyftGrypeScan/scan-git.sh           /app/scan-git.sh
COPY --chown=1001:0 SyftGrypeScan/scan-local.sh         /app/scan-local.sh
COPY --chown=1001:0 SyftGrypeScan/grype-markdown.tmpl   /app/grype-markdown.tmpl
COPY --chown=1001:0 SyftGrypeScan/repos.example.txt     /app/repos.example.txt

# Make scripts executable
RUN chmod +x /app/lib-common.sh /app/scan-git.sh /app/scan-local.sh

# Declare volumes for reports and scan targets
VOLUME ["/reports", "/scan-target", "/repos-config"]

# Default: git scan
ENTRYPOINT ["/bin/bash"]
CMD ["/app/scan-git.sh"]
