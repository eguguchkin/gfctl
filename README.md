# gfctl — CLI для gufo-сервера (Strix Halo / gfx1151)

Деплой и управление сервером **gufo** (официальный образ
`ghcr.io/gufo-org/toolboxes/gufo-runtime`, без форков) с моделями
**qwen3.8-27B** и **qwen3.8-flash-next** — соло и мульти, под агентские
сценарии. Сестринский продукт к hfctl (движок hipfire).

> Статус: этапы 1–3 закрыты, этап 4 (хардening/доставка) в работе — все
> команды карты SPEC §3 живы: установка, профили + probe, bench, watch,
> cache, agent-check, слоёный uninstall с purge-границами.

## Quickstart — 4 команды от клонирования до работающего сервера (SPEC §1)

```bash
git clone <путь-к-репо>/gfctl && cd gfctl   # локальная дистрибуция (D1): rsync -a / scp -r / git по LAN
./install.sh                                # bootstrap: дерево gfctl+lib+tpl → ~/gufo/, симлинк ~/.local/bin/gfctl
gfctl install                               # гейты → веса (после согласия) → юниты → старт → health → smoke → автозапуск
gfctl status                                # проверка: профиль / health / роут / кэш / автозапуск
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

## Полная карта команд

`install` · `use` · `status [--json]` · `logs` · `watch` · `on`/`off` ·
`uninstall [--purge-models] [--purge-image]` · `bench` · `smoke` ·
`agent-check` · `cache [--verify]` · `doctor` ·
`models [--check-types | download <сет>]` · `--help` — все команды живы
(см. `gfctl --help`). Подготовительные шаги при желании — до
`gfctl install`: `gfctl doctor` (диагностика), `gfctl models
--check-types` (pre-check GGUF-типов), `gfctl models download <сет>
[--yes]` (веса отдельно).

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
