FROM rclone/rclone:1.74.4 AS rclone

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Keep the workspace image reproducible and compatible with the Codex app server.
# Bump deliberately when upgrading Codex.
ARG CODEX_RELEASE=${workspace_codex_release}

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    fuse3 \
    jq \
    openssh-client \
    openssh-server \
    python3 \
    python3-pip \
    python3-venv \
    procps \
    util-linux \
    bubblewrap \
    tini \
  && rm -rf /var/lib/apt/lists/*

COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone

RUN curl -fsSL https://chatgpt.com/codex/install.sh -o /tmp/install-codex.sh \
  && CODEX_NON_INTERACTIVE=1 CODEX_RELEASE="$CODEX_RELEASE" CODEX_INSTALL_DIR=/usr/local/bin CODEX_HOME=/opt/codex sh /tmp/install-codex.sh \
  && rm -f /tmp/install-codex.sh

RUN install -d -m 0755 /usr/local/libexec

COPY workspace-entrypoint.sh /usr/local/bin/workspace-entrypoint
COPY workspace-drive-healthcheck /usr/local/bin/workspace-drive-healthcheck
COPY workspace-codex-update.sh /usr/local/libexec/agent-stack-workspace-codex-update
COPY workspace-codex-control.py /usr/local/libexec/agent-stack-workspace-codex-control

RUN chmod 0755 /usr/local/bin/workspace-entrypoint /usr/local/bin/workspace-drive-healthcheck \
  && chmod 0755 /usr/local/libexec/agent-stack-workspace-codex-update \
  && chmod 0755 /usr/local/libexec/agent-stack-workspace-codex-control \
  && printf '%s\n' user_allow_other > /etc/fuse.conf \
  && mkdir -p /run/sshd

EXPOSE 22

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/workspace-entrypoint"]
