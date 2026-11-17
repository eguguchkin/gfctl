# Dev report: 2.1 probe-подбор контекста + gfctl bench
- Дата: 2026-11-17, fix round 0 (первый проход, reviewer ещё не смотрел)
- Реализация строго по `.dev/tasks/2/2.1/task.md` (Design: architect; OQ-1/2/3 решены оркестратором: fallback bench на chat; sessions=4 полный отказ → die + подсказка `--context 65536`; `--context`+`--no-probe` — явный контекст сильнее, WARN печатается)

## What was done

**1. Канон per (профиль × sessions) — `lib/state.sh`**
- `canon_pair_context(prof, sessions)` — плоский ключ `GFCTL_CTX_<профиль_без_дефисов>_<sessions>`; приоритет: пары-ключ (env-оверрайд > .env, механика canon_get) → 1.2-совместимость («миграция чтением»: активные поля GFCTL_PROFILE/GFCTL_SESSIONS совпали с парой → GFCTL_CONTEXT — канон EXP-004 на evo читается без перебора) → пусто (→ probe).
- `write_canon(prof, sessions, context)` — сигнатура прежняя, остаётся ЕДИНСТВЕННЫМ писателем `.env`: render env.tpl → `.env.tmp`, затем допись пар-блока (все строки `^GFCTL_CTX_` из старого .env КРОМЕ ключа этой пары + актуальная строка) → mv (атомарность 1.2). Upsert: чужие пары сохраняются, дублей нет; каждое успешное use пишет ОБА представления (активные поля + пару-ключ) — boot/watchdog 1.2 не сломаны. env.tpl не менялся.

**2. probe-механика — `probe_context` + `probe_log` в `lib/commands.sh`**
- Перебор лестницы поля 8 по убыванию; каждая попытка — env-оверрайд `GFCTL_SESSIONS=… GFCTL_CONTEXT=…` поверх `container_up` (канон на диске НЕ меняется ни при отказе попытки, ни при отказе всего probe — свойство отката; пауза F10 — встроенная в container_up) + `wait_load 180`.
- `probe_log` — строка в журнал `logs/probe-<профиль>-<sessions>.log` (обнуляется на старте) + та же строка в stdout («ступень X: …» — прогресс худшего случая 94 с × 5, F5).
- Вердикты: `load_failed (admission/отказ загрузки)` (ранний выход 20 с, GFCTL_LOADFAIL_AFTER — переиспользован из 1.2) / `таймаут 180с` / успех (wait_load rc 0 → `PROBE_CTX`, глобал как ROUTE_*).
- Полный отказ: таблица попыток (журнал построчно) в stderr + die «…это тоже результат (PLAN)…» с подсказкой `--context N`; для sessions=4 — подсказка `--context 65536` (floor 4×65536 проверен F6, 65536 в лестнице нет — OQ-2a). Infra-отказ podman run — container_up сам die, в таблицу не попадает.

**3. `cmd_use` — дерево решений (замена тела 1.2 после ensure_weights)**
- `--context N` → он («probe пропущен»; при `--no-probe` вместе — WARN, OQ-3); канон пары непуст → «probe пропущен» (WARN, если `--no-probe`); канон пуст + `--no-probe` → WARN + последняя (минимальная) ступень лестницы (для single — поле 4, поведение 1.2 сохранено, секция §18 зелёная без правки); канон пуст + лестница '-' → поле 4; иначе → `probe_context`.
- `write_canon` (оба представления) → probe-путь: контейнер УЖЕ поднят попыткой → сразу `wait_health 180 → smoke` БЕЗ второго recreate (экономия до 94 с, F5); остальные пути — `container_up → wait_health → smoke` (порядок 1.2). Печать канона — строка 1.2 без изменений.

**4. `cmd_bench` + `bench_request` в `lib/commands.sh` (заглушка снята)**
- Гейты по порядку: container running → port_open(canon_port) → parse_route (ROUTE_MODEL) → md5-гейт фикстуры `253c7ac50857fe6d0e10fb0d2c5e35c0` (die «сравнимость прогонов потеряна (F12)»).
- 1 прогрев + 3 замера POST `/v1/completions`: prompt = байты фикстуры как есть (python3 stdlib json), temperature 0, max_tokens 256, одиночный запрос; wall = `date +%s.%N` вокруг curl; «прогон N: wall X.Xs | M tok | Y.Y tok/s» (completion_tokens из usage); медианы через `sort -n | sed -n 2p`; строка «медиана: wall X.Xs | Y.Y tok/s». Отказ curl / битый JSON / пустой usage → die БЕЗ ретрая.
- `bench_request` — транспорт изолирован в одной функции; fallback на `/v1/chat/completions` (OQ-1 оркестратора: prompt → messages[0], `chat_template_kwargs.enable_thinking=false`, WARN «числа теряют прямую сравнимость с каноном»). Ответ — mktemp под $TMPDIR, cleanup EXIT-trap (`resp` — глобальная функции: локальная ломала trap под set -u). Деление на ноль wall защищено.

**5. Диспетчер `gfctl`**: `bench` → `cmd_bench "$@"` (из die-ветки; watch/cache/agent-check остались заглушками этапа 3), usage-строка bench без пометки `[этап 2]`, комментарий роутера обновлён.

**6. Батарея `tests/run_checks.sh`** (замены строго по п.0 task.md; секции 1–13, 15–25 нетронуты):
- faux-bin: faux `podman run` запоминает `--context <N>` в `$GFCTL_FAUX_CNT.ctx`; faux `podman logs` маппит `GFCTL_FAUX_CTX_LOGS="ctx:файл …"` по текущему ctx с fallback на GFCTL_FAUX_PODMAN_LOGS (механика — по args run, не по счётчику); faux curl — ветка `/v1/completions` (детерминированный JSON с usage.completion_tokens=256, FAILFIRST/FAILALL общие).
- §2: заглушки остались РОВНО у watch/cache/agent-check (этап 3); bench перенесён в цикл не-заглушек; ассерт usage без «bench…этап».
- §14: ожидание `.env` = env.tpl + пар-блок; upsert (чужая пара сохранена, без дублей); canon_pair_context (ключ / 1.2-fallback / env-оверрайд пары / пусто на чужих парах).
- Новые секции: §26 (probe 27b-multi fail→ok: порядок лестницы, РОВНО 2 run — успех без второго recreate, журнал, канон пары), §27 (flash 262144→229376→196608, 3 run), §28 (полный отказ → die + таблица + `.env` байт-в-байт цел + ровно 3 попытки; sessions=4 → подсказка 65536, журнал 5 отказов), §29 (повторный use = «probe пропущен», ровно 1 run), §30 (`--no-probe` без канона → минимальная ступень + фиксация в каноне; с каноном → канон; WARN всегда), §31 (sessions=4: `--sessions 4 --context 262144`, flash_multi_2 сохранён + flash_multi_4 добавлен), §32 (bench живой: 4 curl, прогрев+3+медиана, только /v1/completions; мёртвый порт; нет контейнера; md5-гейт на КОПИИ tpl; FAILALL → 2 curl и die).

Файлы: `gfctl`, `lib/state.sh`, `lib/commands.sh`, `tests/run_checks.sh`. (lib/serve.sh, lib/health.sh, lib/profiles.sh, tpl/** — не тронуты; фикстура bench НЕ редактировалась.)

## How it was checked internally

| check | команда | результат |
|---|---|---|
| синтаксис | `bash -n gfctl lib/*.sh` | OK |
| python | `python3 -m py_compile tpl/python/*.py` | OK |
| bare-вызов | `./gfctl` | rc=1 + usage |
| status мёртвый порт | `GFCTL_PORT=8198 ./gfctl status --json` | rc=0, валидный JSON |
| md5-гейт фикстуры | `md5sum tpl/bench/merge_sort_thinking_off.txt` | `253c7ac50857fe6d0e10fb0d2c5e35c0` |
| **батарея** | `bash tests/run_checks.sh` | **ИТОГО: PASS=218 FAIL=0** (прогнан 3 раза, стабилен) |

Регресс 1.1+1.2: секции 1–13, 15–25 без правок и зелёные (180 ассертов этапа 1 preserved); 2.1 добавил 38 ассертов (§26–§32 + правки §2/§14). Инварианты батареи: попытки лестницы строго по порядку убывания; канон на диске не пишется между попытками и не портится при полном отказе (cmp байт-в-байт); успех probe без второго podman run; bench-сводка детерминирована по структуре (wall — реальное время, число не фиксируется).

## Not checked internally

- **`load_failed` как имя события отказа gufo** — design-константа 1.2 (F17: живьём не наблюдался; F13 — формат admission-отказа 27B 2×262144 подтверждён в окне, но имя события в логе gufo при probe не снято). Если gufo пишет иначе — ступени завершатся таймаутом 180 с (корректно, медленнее; риск task.md §Risks). Подтвердить: **EXP-006-evo-probe** (первым делом), факт — в FACTS.
- **`/v1/completions` на gufo не подтверждён факт-базой** — EXP-005/006 проверяют эндпоинт первым действием; fallback на chat вшит в bench_request (правка одной функции при смене), числа fallback теряют прямую сравнимость с каноном 76.9 t/s (F12) — зафиксировать в FACTS после окна.
- **Полный отказ 4-сессионной лестницы flash** (65536 в лестнице нет) — живое поведение не проверяемо без GPU; EXP-005-faex. Если полный отказ — правка SPEC §5 (хвост 65536) отдельным дельта по факту (OQ-2).
- **EXP-заготовки EXP-005-faex / EXP-006-evo-probe в очередь НЕ поставлены** — по протоколу dev-flow очередь EXP ставит tester; я их не писал и не исполнял (BLOCKED-EXTERNAL). Напоминание tester'у от task.md: EXP-006 ОБЯЗАН сбросить канон пары (строки `GFCTL_CTX_*`/активные поля `.env`) перед use — иначе канон выигрывает (SPEC §9) и probe не запустится.
- Живой `md5sum`/`date +%s.%N` на целевой машине — GNU-машины по AGENTS, локально то же поведение.

## Known limitations / assumptions

- `install` (cmd_install) по-прежнему пишет канон из полей 3/4 таблицы БЕЗ probe — SPEC §3 упоминает probe в install, но task.md §3 ограничивает интеграцию cmd_use'ом (осознанный скоуп; предложение — см. Out-of-scope).
- Probe-путь оставляет «чужой» активный канон в .env на время попыток (например, актуальный профиль 27b-single при probe flash-multi) — инвариант «канон на диске == конфиг работающего контейнера» восстанавливается write_canon после успеха; при смерти probe в середине вотчдог/boot поднимут прежний канон (свойство отката, зафиксировано батареей §28).
- Гонка двух писателей .env вне модели отказа (как в 1.2) — однопользовательский CLI; атомарность mv сохранена.
- Faux-числа bench (wall 0.0s → tok/s ~2.5e8) — артефакт мгновенной заглушки, не прод-логика.
- Fallback bench_request срабатывает на КАЖДОМ из 4 запросов (худший случай 8 curl-вызовов) — осознано: изоляция транспорта в одной функции важнее кэша эндпоинта.

## Out-of-scope proposals

- `install` с probe-подбором (унификация с cmd_use) — SPEC §3 это обещает; сейчас только use. Отдельный сабстэдж/фикс-раунд.
- Ротация probe-журнала и force-re-probe флаг — спек §9 (канон выигрывает); вне скоупа task.md, оставлено в бэклоге.
- Парный агрегат-замер bench (EXP-004-стиль, 2 параллельных запроса по 600 ток) — отдельная история (brief 2.1: bench = одиночный запрос).
