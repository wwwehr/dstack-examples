FROM nginx:1.29.4

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openssl \
        bash \
        python3-pip \
        python3-requests \
        python3-venv \
        curl \
        jq \
        coreutils && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p \
    /etc/letsencrypt \
    /var/www/certbot \
    /usr/share/nginx/html \
    /etc/nginx/conf.d \
    /var/log/nginx

# Install scripts with deterministic permissions via bind mount
RUN --mount=type=bind,source=scripts,target=/tmp/scripts,ro \
    /bin/bash -o pipefail -c 'set -euo pipefail; \
        rm -rf /scripts && mkdir -p /scripts && chmod 755 /scripts && \
        cd /tmp/scripts && \
        find . -type d -print0 | while IFS= read -r -d "" dir; do \
            rel="${dir#./}"; \
            [[ -z "$rel" ]] && continue; \
            install -d -m 755 "/scripts/$rel"; \
        done && \
        find . -type f -print0 | while IFS= read -r -d "" file; do \
            rel="${file#./}"; \
            perm=644; \
            case "$rel" in \
                *.sh) perm=755 ;; \
                *.py) case "$rel" in */*) perm=644 ;; *) perm=755 ;; esac ;; \
            esac; \
            install -m "$perm" "$file" "/scripts/$rel"; \
        done'

ENV PATH="/scripts:$PATH"
ENV PYTHONPATH="/scripts"
COPY --chmod=666 .GIT_REV /etc/

ENTRYPOINT ["/scripts/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
