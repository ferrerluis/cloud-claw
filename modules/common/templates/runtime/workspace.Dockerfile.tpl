FROM rclone/rclone:1.74.4 AS rclone

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    openssh-client \
    openssh-server \
    procps \
    bubblewrap \
    fuse3 \
    tini \
    util-linux \
  && rm -rf /var/lib/apt/lists/*

COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone

RUN curl -fsSL https://chatgpt.com/codex/install.sh -o /tmp/install-codex.sh \
  && CODEX_NON_INTERACTIVE=1 CODEX_INSTALL_DIR=/usr/local/bin CODEX_HOME=/opt/codex sh /tmp/install-codex.sh \
  && rm -f /tmp/install-codex.sh

COPY workspace-entrypoint.sh /usr/local/bin/workspace-entrypoint
COPY workspace-drive-healthcheck /usr/local/bin/workspace-drive-healthcheck

RUN chmod 0755 /usr/local/bin/workspace-entrypoint /usr/local/bin/workspace-drive-healthcheck \
  && printf '%s\n' user_allow_other > /etc/fuse.conf \
  && mkdir -p /run/sshd

EXPOSE 22

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/workspace-entrypoint"]
