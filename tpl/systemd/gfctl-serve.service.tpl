[Unit]
Description=gufo serve (podman run, gfctl) — boot-юнит канона профиля
After=podman-user-wait-network-online.service

[Service]
Type=oneshot
RemainAfterExit=yes
# ВАЖНО: без KillMode=process systemd при остановке юнита убивает весь
# cgroup — вместе с контейнером gufo (SIGTERM/143).
KillMode=process
WorkingDirectory=__STACK_DIR__
# env диспетчера в юните: без них _boot взял бы дефолты (каталог gfctl-файла
# + профили по умолчанию) — дефект EXP-009 (ребут = цикл падений).
Environment=GFCTL_DIR=__GFCTL_DIR__
Environment=GFCTL_MODELS=__GFCTL_MODELS__
ExecStart=/usr/bin/env bash __STACK_DIR__/gfctl _boot
# Страховка при systemctl stop живого юнита; рабочий stop — gfctl off
# (у завершённого oneshot ExecStop не стреляет).
ExecStop=__PODMAN_BIN__ rm -f __CONTAINER__
TimeoutStartSec=900
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
