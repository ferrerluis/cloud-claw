[Unit]
Description=AgentStack Tailscale sidecar watchdog
After=agent-stack.service
Requires=agent-stack.service

[Service]
Type=simple
ExecStart=/usr/local/bin/agent-stack-tailscale-watchdog
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
