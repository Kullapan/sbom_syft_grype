# ============================================================
# OpenShift Dockerfile for Dependency-Track API
# Built from the official image
# ============================================================

FROM dependencytrack/apiserver:latest

# Switch to root to fix permissions for OpenShift's restricted SCC
USER root

# Ensure the data directory and application directory are writable by the root group
RUN mkdir -p /data && \
    chown -R 1000:0 /data /opt/dependency-track && \
    chmod -R g+rwX /data /opt/dependency-track

# Revert to standard user (usually 1000 in official DTrack image)
USER 1000

# The official image already has the correct EXPOSE and ENTRYPOINT
