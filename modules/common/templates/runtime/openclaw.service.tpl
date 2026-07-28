[Unit]
Description=Compatibility wrapper for AgentStack
Requires=agent-stack.service
After=agent-stack.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/systemctl start agent-stack.service

[Install]
WantedBy=multi-user.target
