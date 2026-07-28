[Unit]
Description=Daily AgentStack workspace Codex hard-maintenance update

[Timer]
OnCalendar=*-*-* ${workspace_codex_auto_update_time}:00 ${workspace_codex_auto_update_timezone}
Persistent=false
AccuracySec=1s
RandomizedDelaySec=0
Unit=agent-stack-workspace-codex-update.service

[Install]
WantedBy=timers.target
