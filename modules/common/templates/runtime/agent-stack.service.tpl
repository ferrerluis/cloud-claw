[Unit]
Description=AgentStack
Documentation=https://github.com/openclaw/openclaw
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/agent-stack
ExecStartPre=/usr/local/bin/agent-stack-migrate-layout
ExecStartPre=/bin/sh -lc '/usr/bin/docker compose pull --quiet --ignore-buildable || true'
ExecStart=/usr/bin/docker compose up --remove-orphans
ExecStop=/usr/bin/docker compose down
Restart=on-failure
RestartSec=15
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
