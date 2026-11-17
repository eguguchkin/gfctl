# gfctl — CLI для gufo-сервера (Strix Halo / gfx1151)

Деплой и управление сервером **gufo** (официальный образ
`ghcr.io/gufo-org/toolboxes/gufo-runtime`, без форков) с моделями
**qwen3.8-27B** и **qwen3.8-flash-next** — соло и мульти, под агентские
сценарии. Сестринский продукт к hfctl (движок hipfire).

> Статус: каркас этапа 1 (сабстэдж 1.1) — работают read-only/подготовительные
> команды: `doctor`, `models`, `status`. Серверная часть (`install`, `use`,
> `on/off`, `smoke`, автозапуск) — сабстэдж 1.2; `bench` — этап 2; `watch`,
> `cache`, `agent-check` — этап 3.

## Quickstart

```bash
# 1. перенести каталог репо на машину (rsync -a / scp -r / git по LAN)
cd gfctl
./install.sh          # дерево gfctl+lib+tpl → ~/gufo/, симлинк ~/.local/bin/gfctl
gfctl doctor          # диагностика: ОС, /dev/kfd, render, memlock, linger,
                      # RAM-гейты всех профилей, диск, порт, gpu-lock

# 2. веса (после согласия; pre-flight «нужно X GiB», curl resume, sha256)
gfctl models download 27b [--yes]     # set: 27b | flash | <профиль>

# 3. pre-check GGUF-типов (unsloth UD-* для 27B не грузятся — IQ2_S/IQ3_XXS
#    в FFN → КРАСНЫЙ «не загрузится»)
gfctl models --check-types

# 4. инвентарь и статус
gfctl models          # скачано vs требуется по профилям, sha-статус, место
gfctl status [--json] # профиль / health / роут / кэш / автозапуск
```

## Профили

| профиль | сет | RAM-гейт | sessions × context | спекуляция |
|---|---|---|---|---|
| `27b-single` ⭐ | pure-IQ4_XS + DFlash2 draft | ≥56 GiB | 1 × 262144 | dflash2 |
| `27b-multi` | те же | ≥56 GiB | 2 × 163840 (probe до 196608) | dflash2 |
| `flash-multi` | UD-Q4_K_XL 4 шара + MTP | ≥110 GiB | 2 × max (probe-лестница, floor 131072) | mtp |

Порт по умолчанию **8080**, bind `0.0.0.0`. Конфигурация env'ами:
`GFCTL_IMAGE`, `GFCTL_DIR`, `GFCTL_MODELS`, `GFCTL_PORT`, `GFCTL_BIND`,
`GFCTL_YES`. Инсталляция живёт в `~/gufo/`.

## Полная карта команд (итог этапа 1)

`install` · `use` · `status [--json]` · `logs` · `watch` · `on`/`off` ·
`uninstall` · `bench` · `smoke` · `agent-check` · `cache [--verify]` ·
`doctor` · `models [--check-types | download <сет>]` · `--help`.
Помеченные «этап 1.2/3» в `gfctl --help` пока отвечают rc=1 с указанием этапа.

## Разработка

- Протокол: dev-flow, blackboard `.dev/` (SPEC.md, PLAN.md, FACTS.md,
  DECISIONS.md, STATE.md, tasks/).
- Internal checks одной командой: `bash tests/run_checks.sh`
  (`bash -n`, `py_compile`, диспетчер, таблицы vs task.md, мини-GGUF
  фикстуры, doctor/status). Зависимостей нет: bash + python3 stdlib
  (+ podman/curl на целевой машине).

## Схема репо

```
gfctl          # диспетчер (env-шапка + log/warn/die/ask + case-роутер)
install.sh     # bootstrap: ~/gufo + симлинк (полное поведение — этап 1.2/4)
lib/           # profiles.sh, models.sh, commands.sh (модули добавляются по мере команд)
tpl/python/    # gguf_type_check.py — потоковый pre-check GGUF-типов
tpl/bench/     # merge_sort_thinking_off.txt — канон фикстуры bench (md5 253c7ac5)
tests/         # run_checks.sh + make_fixtures.py + fixtures/*.gguf (мини-GGUF ассеты)
.dev/          # blackboard dev-flow
```
