[Unit]
Description=gufo watchdog timer (gfctl, 1 min)

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
RandomizedDelaySec=10

[Install]
WantedBy=timers.target
