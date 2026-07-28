[Unit]
Description=AgentStack workspace Codex stable-channel updater
Requires=docker.service
After=docker.service agent-stack.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/agent-stack-workspace-codex-update --scheduled
TimeoutStartSec=50min
