[Unit]
Description=Run AgentStack Tailscale watchdog

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
Unit=agent-stack-tailscale-watchdog.service

[Install]
WantedBy=timers.target
