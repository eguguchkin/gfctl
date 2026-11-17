[Unit]
Description=gufo watchdog (gfctl): поднимает контейнер после нештатного падения

[Service]
Type=oneshot
# ВАЖНО: без KillMode=process systemd при завершении oneshot-юнита убивает
# весь cgroup — вместе с только что поднятым контейнером (SIGTERM/143).
KillMode=process
ExecStart=/usr/bin/env bash __STACK_DIR__/gfctl _watchdog
