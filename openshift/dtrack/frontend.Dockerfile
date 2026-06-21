# ============================================================
# OpenShift Dockerfile for Dependency-Track Frontend
# Built from the official image
# ============================================================

FROM dependencytrack/frontend:latest

# Switch to root to fix permissions for OpenShift's restricted SCC
USER root

# Ensure Nginx paths are writable by the root group
RUN mkdir -p /var/cache/nginx /var/run /var/log/nginx /usr/share/nginx/html /etc/nginx/conf.d && \
    chown -R 1000:0 /var/cache/nginx /var/run /var/log/nginx /usr/share/nginx/html /etc/nginx/conf.d && \
    chmod -R g+rwX /var/cache/nginx /var/run /var/log/nginx /usr/share/nginx/html /etc/nginx/conf.d && \
    # Remove default nginx user config to avoid issues
    sed -i '/user  nginx;/d' /etc/nginx/nginx.conf && \
    # Change pid file location
    sed -i 's|/var/run/nginx.pid|/tmp/nginx.pid|' /etc/nginx/nginx.conf

# Modify default port from 80 to 8080 since non-root users can't bind to ports < 1024
RUN sed -i 's/listen       80;/listen       8080;/g' /etc/nginx/conf.d/default.conf || true

# Revert to standard user
USER 1000
EXPOSE 8080

# The official image already has the correct ENTRYPOINT/CMD
