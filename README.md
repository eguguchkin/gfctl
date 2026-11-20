# gfctl — CLI для gufo-сервера (Strix Halo / gfx1151)

Деплой и управление сервером **gufo** (официальный образ
`ghcr.io/gufo-org/toolboxes/gufo-runtime`, без форков) с моделями
**qwen3.8-27B** и **qwen3.8-flash-next** — соло и мульти, под агентские
сценарии. Сестринский продукт к hfctl (движок hipfire).

> Статус: этапы 1–4 закрыты. Лейаут 4.4: одна папка = git-клон = стек;
> данные сервера в `.data/` (инвариант — uninstall и `git clean -fd` их не
> трогают); `install.sh` упразднён — bootstrap первого запуска делает сам
> диспетчер.

## Quickstart — 4 команды от клонирования до работающего сервера

```bash
git clone https://github.com/eguguchkin/gfctl && cd gfctl   # клон = стек: gfctl, lib/, tpl/, данные .data/
./gfctl use 27b-single    # bootstrap .data/ → веса (после согласия) → юниты → старт → health → smoke
./gfctl status            # профиль / health / роут / кэш / автозапуск
./gfctl watch             # живой дашборд (/metrics + host /proc+/sys + логи)
```

gfctl работает от местоположения gfctl-файла (не от cwd) — запуск из любого
подкаталога клона и через симлинк указывает на тот же стек. Данные живут в
`.data/` клона (вне git): `models/{27b,flash}`, `cache/<профиль>`, `logs/`.
Поэтому **`git clean -fd` безопасен, а `git clean -fdx` ЗАПРЕЩЁН** — он
удалит модели/кэш/логи. Вернуть сервер после `gfctl off`/`uninstall` —
`gfctl on` (юниты + linger) или снова `gfctl use <профиль>`. Одна
инсталляция на пользователя: второй клон = конфликт имени контейнера `gufo`
и порта 8080.

## Профили

| профиль | сет | RAM-гейт | sessions × context | спекуляция |
|---|---|---|---|---|
| `27b-single` ⭐ | pure-IQ4_XS + DFlash2 draft | ≥56 GiB | 1 × 262144 | dflash2 |
| `27b-multi` | те же | ≥56 GiB | 2 × 163840 (probe до 196608) | dflash2 |
| `flash-multi` | UD-Q4_K_XL 4 шара + MTP | ≥110 GiB | 2 × max (probe-лестница, floor 131072) | mtp |

Порт по умолчанию **8080**, bind `0.0.0.0`. Конфигурация env'ами:
`GFCTL_IMAGE`, `GFCTL_DIR` (каталог стека; по умолчанию — каталог
gfctl-файла), `GFCTL_MODELS`, `GFCTL_PORT`, `GFCTL_BIND`, `GFCTL_YES`.

## Полная карта команд

`install` · `use` · `status [--json]` · `logs` · `watch` · `on`/`off` ·
`uninstall` · `bench` · `smoke` · `agent-check` · `cache [--verify]` ·
`doctor` · `models [--check-types | download <сет>]` · `--help` — все
команды живы (см. `gfctl --help`). `use`/`install` сами ставят юниты
идемпотентно (после записи канона). `uninstall` снимает контейнер + юниты +
watchdog + linger + limits.d-файл и **не трогает данные**: `.data/` и
podman-образ остаются — полный снос руками (`rm -rf <клон>` +
`podman rmi <образ>`). Подготовительные шаги при желании — до `gfctl use`:
`gfctl doctor` (диагностика), `gfctl models --check-types` (pre-check
GGUF-типов), `gfctl models download <сет> [--yes]` (веса отдельно).

## Разработка

- Протокол: dev-flow, blackboard `.dev/` (SPEC.md, PLAN.md, FACTS.md,
  DECISIONS.md, STATE.md, tasks/).
- Internal checks одной командой: `bash tests/run_checks.sh`
  (`bash -n`, `py_compile`, диспетчер, таблицы vs task.md, мини-GGUF
  фикстуры, doctor/status). Зависимостей нет: bash + python3 stdlib
  (+ podman/curl на целевой машине).

## Схема репо

```
gfctl          # диспетчер: STACK_DIR-детект (каталог gfctl-файла) + bootstrap первого запуска + роутер
lib/           # profiles.sh, models.sh, state.sh, serve.sh, units.sh, health.sh, agentcheck.sh, autostart.sh, commands.sh
tpl/           # systemd-юниты, python-харнесы (watch/agent-check/gguf/smoke), bench-фикстура, env-шаблон
tests/         # run_checks.sh + make_fixtures.py + fixtures/*.gguf (мини-GGUF ассеты)
.data/         # ДАННЫЕ сервера (вне git, создаёт bootstrap): models/{27b,flash}, cache/<профиль>, logs/
.dev/          # blackboard dev-flow
```
