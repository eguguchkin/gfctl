[Unit]
Description=gufo watchdog (gfctl): поднимает контейнер после нештатного падения

[Service]
Type=oneshot
# ВАЖНО: без KillMode=process systemd при завершении oneshot-юнита убивает
# весь cgroup — вместе с только что поднятым контейнером (SIGTERM/143).
KillMode=process
# env диспетчера в юните: без них _watchdog взял бы дефолты ($HOME/gufo) —
# дефект EXP-009 (ребут acc-инсталляции = цикл падений).
Environment=GFCTL_DIR=__GFCTL_DIR__
Environment=GFCTL_MODELS=__GFCTL_MODELS__
ExecStart=/usr/bin/env bash __STACK_DIR__/gfctl _watchdog
