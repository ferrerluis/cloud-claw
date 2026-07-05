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
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://chatgpt.com/codex/install.sh -o /tmp/install-codex.sh \
  && CODEX_NON_INTERACTIVE=1 CODEX_INSTALL_DIR=/usr/local/bin CODEX_HOME=/opt/codex sh /tmp/install-codex.sh \
  && rm -f /tmp/install-codex.sh

COPY workspace-entrypoint.sh /usr/local/bin/workspace-entrypoint

RUN chmod 0755 /usr/local/bin/workspace-entrypoint \
  && mkdir -p /run/sshd

EXPOSE 22

CMD ["/usr/local/bin/workspace-entrypoint"]
