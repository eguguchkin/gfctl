# Dev report: 3.1 agent-check + cache + watch

- Date: 2026-11-18 / fix round: 1 (первый проход)
- Реализация строго по `.dev/tasks/3/3.1/task.md` (Design architect);
  OQ 1–3 закрыты по рекомендациям (неснятый референс → WARN «эталон не
  снят»; /metrics best-effort не-фатально; рестарт — warn без ask).

## What was done

**Новые файлы:**
- `lib/agentcheck.sh` — `cmp_ref` (чистая функция: ref='' → WARN «не снят»;
  ≤ ref×1.25 → PASS; иначе WARN «регрессия >25%» + hint-хвост для
  follow-up/restore; float через awk) + `cmd_agentcheck` (гейты
  running→port→ROUTE_MODEL → warn рестарта → python stage1 → cmp_ref по
  CHECK-строкам (сессия/follow-up 25k с hint/docq; 5k/100k — печать без
  сравнения) → `container_up "$(cur_profile)"` → `wait_health 180` →
  python stage2 → cmp_ref restore + reuse-вердикт (live|disk ok, none →
  FAIL) → сводка `AGENT-CHECK: PASS=N WARN=M FAIL=K`; rc 0 при FAIL=0,
  exit 1 при FAIL, die при структурном провале ДО сводки; state-файл
  `$LOGS_DIR/agent-check-restore.json` удаляется после использования).
- `tpl/python/agent_check.py` — 4 режима (stage1 = 24 POST: сессия 15
  ходов (16 фактов ×11 ≈ 6.6k ток, история растёт) + лестница 5k/25k/100k
  (6) + docq (2) + restore-turn1 (1); stage2 = 1 POST; cacheverify1 = 2;
  cacheverify2 = 1 → ровно 25 в agent-check). Конверт окон FX/CX:
  `temperature: 0`, `reasoning_effort: "none"`, max_tokens по сценарию;
  timings читаются ИЗ ТЕЛА (`timings.component_cache.reuse`), отсутствие
  timings → структурный FAIL rc 1 с явной причиной; один ретрай только у
  первого запроса прогона (F15, пауза `GFCTL_SMOKE_RETRY_S`); промпты —
  литералы файла (без bench-фикстуры, F12; без IP/хостов); stdlib only.
- `tpl/python/watch_tui.py` — адаптация каркаса hfctl: TUI (curses,
  alt-экран, блоки «Движок»/«Память»/«Скорость»/«Логи», остаток высоты —
  Логи) и plain-стрим по `isatty()`; слой данных перестроен под gufo:
  /stats УБРАН, /metrics — единственный движковый источник, печатаются
  СЫРЫЕ `llamacpp:*` (имена не выдумываются; cached_total — единственный
  подтверждённый ключ); model/uptime — из сида логов (model= до
  `sessions=`, как parse_route; uptime — от первого timestamp); «Память»
  — /proc/meminfo + первая `temp*_input` hwmon; `podman logs -f`
  (deque 500, stderr→stdout); клавиши q/+/−/p; мёртвый сервер — ровно
  одна строка «недоступен» на тик (plain) / блок «недоступен» (TUI),
  без traceback; швы батареи: `GFCTL_WATCH_TICKS` (N тиков и выход),
  interval <0.05 — без сна, `GFCTL_WATCH_SELFCHECK=1` (24 assert'а
  парсера/рендера — 24/24 ok); env-входы без argv (паттерн hfctl).

**Изменённые:**
- `lib/profiles.sh` — ref-слой скаляров рядом с таблицей (НЕ 10-е поле):
  `ref_27b_single_session=23.8 / followup=1.7 / restore=0.81`
  (AGENT-CONFIGS п.3) + `ref_get <профиль> <метрика>` (indirect-раскрытие,
  дефисы→подчёркивания; '' = не снят, rc 0 всегда). flash-multi/
  27b-multi/docq — unset до EXP-007 → WARN «эталон не снят».
- `lib/commands.sh` — `parse_configured` (чистая, stdin=лог; ПОСЛЕДНЯЯ
  `event=configured`; `\b`-граница, чтобы capacity_bytes не ловил
  disk_capacity_bytes; глобалы CC_*; нет строки = норма) · `fs_type`
  (обёртка `stat -f -c %T` — шов батареи) · `cache_verify` (follow-up →
  reuse-вердикт: live|disk PASS, none → die «проверь --cache-ram-bytes»;
  tmpfs → WARN; warn рестарта ДО recreate → container_up → wait_health →
  cacheverify2 → reuse disk|live PASS / иначе FAIL rc 1) · `cmd_cache`
  (rc 0 всегда: каталог+du -sb, configured в GiB, skipped/evicted —
  count-only `grep -c`, `/metrics` cached_total через awk по точному
  имени ключа — «?» при отказе) · `cmd_watch` (только `--interval
  N|=N`, целое ≥1 → `exec python3` с env GFCTL_WATCH_PORT/INTERVAL/
  CONTAINER — паттерн hfctl 1:1).
- `gfctl` — usage: у watch/agent-check/cache снята пометка «[этап 3]»
  (остальные строки байт-в-байт); source `lib/agentcheck.sh` (после
  health.sh); роутер: die-ветка этапа 3 исчезла → `watch) cmd_watch`,
  `cache) cmd_cache`, `agent-check) cmd_agentcheck`; комментарий роутера
  обновлён.
- `tests/run_checks.sh` — faux-bin 6→7 заглушек: faux `stat`
  (GFCTL_FAUX_STAT_FSTYPE → печать типа; unset → passthrough реальному
  stat — /usr/bin или /bin, контейнеры бывают без usrmerge); faux curl:
  ветка `/metrics` (канон `llamacpp:prompt_tokens_cached_total 539`,
  оверрайд GFCTL_FAUX_METRICS, счётчик общий .curl, FAILALL валит) + в
  chat-ответ флаг `GFCTL_FAUX_CURL_TIMINGS=1` добавляет top-level
  `"timings"` с `component_cache.reuse` (сценарий `GFCTL_FAUX_CURL_REUSE`);
  gf-harness подключает agentcheck.sh; §2: заглушечный цикл заменён на
  «не-заглушка» (watch/cache/agent-check) + грамматика 5 форм + usage без
  «[этап 3]»; новые секции: §33 cmp_ref/ref_get (9), §34/34a agent-check
  happy + структурные FAIL (17), §35 cache/parse_configured (10), §36
  cache --verify + tmpfs (10), §37 watch plain/мёртвый/selfcheck/через
  диспетчер (12). Секции 1.1–2.1 не тронуты.
- `.dev/external/EXP-007-agentcheck.sh` — ЗАГОТОВКА окна (D6, не
  исполняется): bootstrap-first remote (урок F21), agent-check на
  flash-multi (FAEX, re-shoot референсов) и 27b-single (evo, против
  23.8/1.7/0.81), cache --verify + fs_type, сбор сырых `llamacpp:*`
  ключей и образцов skipped/evicted, PASS-критерии, `gfctl off` в конце.

**Счётчики POST agent-check**: 15 (сессия) + 6 (лестница 3×2) + 2 (docq)
+ 2 (restore turn1+turn2) = 25 — ассерт батареи; cache --verify = 3.

## How it was checked internally

| команда | результат |
|---|---|
| `bash -n gfctl lib/*.sh` | OK |
| `python3 -m py_compile tpl/python/*.py` | OK |
| `bash tests/run_checks.sh` | **ИТОГО: PASS=289 FAIL=0** (было 233; два прогона подряд — стабильно) |
| `GFCTL_WATCH_SELFCHECK=1 python3 tpl/python/watch_tui.py` | selfcheck: 24/24 ok, rc 0 |
| `md5sum tpl/bench/merge_sort_thinking_off.txt` | `253c7ac5…` — фикстура не тронута (F12) |
| `./gfctl` (bare) | rc=1 + usage |
| `GFCTL_PORT=8199 ./gfctl status --json` | rc=0, валидный JSON (мёртвый порт) |
| живая проба `./gfctl cache` / `./gfctl agent-check` без стека | честный отказ/сводка без краша (rc 1/0) |
| `GFCTL_WATCH_TICKS=1 gfctl watch --interval=3` (не-TTY) | один срез блоков, rc 0 |
| `bash -n .dev/external/EXP-007-agentcheck.sh` | OK (не исполнялся — D6) |

Ключевые батаре-ассерты новой логики: ровно 25 chat-POST и 4 CHECK-строки;
порядок по FAUXLOG (warn-рестарт и 24-й POST ДО `podman rm`, restore-POST
после); структурный FAIL (curl FAILALL / timings-нет) → rc 1 ДО сводки;
parse_configured «последняя побеждает» + `\b`-граница; reuse=none → rc 1
ДО рестарта; tmpfs→WARN / ext4→нет WARN; watch: счётчик /metrics = тикам,
мёртвый сервер = ровно 3 строки «недоступен» без traceback; тайминги НЕ
ассертятся (машино-зависимы) — только вердикты/структура.

## Not checked internally (BLOCKED-EXTERNAL — EXP-007, GO пользователя)

- Живой `agent-check` на gufo: реальный контракт `timings`/
  `component_cache.reuse` в теле ответа (наблюдён в окнах FX/CX, но не
  зафиксирован в доках gufo — при исчезновении поля деградация в
  структурный FAIL с явной причиной, не тихо).
- Живые референсы flash-multi (2×262144) и docq всех профилей →
  заполнение `ref_*` в profiles.sh после окна.
- `reuse=disk` после живого рестарта (cache-disk-тир, F17-аналог) и
  рестарт-restore на реальной загрузке (~15–100 c).
- watch TUI на SSH-TTY: клавиши q/+/−/p, рендер в реальном терминале
  (батарея покрывает только plain + selfcheck-скелет).
- Живой `stat -f -c %T` кэш-каталога и форматы строк `event=skipped/
  evict*` (сбор образцов заложен в EXP-007).

## Known limitations / assumptions

- **Транспорт python — curl из PATH, а не urllib** (расхождение с буквой
  Design §3 «curl-независимый python urllib»): Test strategy 3.1 прямо
  требует faux-curl-шов с общим счётчиком и флагом timings для §A/§C2/D,
  Risks формулирует лимит как «-m 1200» (curl-флаг). Envelope запроса
  байт-в-байт по протоколу окон; решение принято в пользу опертивного
  контракта тестов — прошу tester/reviewer подтвердить.
- plain-стрим: 4 строки/тик ([движок]/[скорость]/[память]/[логи]); при
  мёртвом сервере — РОВНО одна строка «недоступен» (логи/срез
  подавляются — по DoD «без спама»).
- uptime watch — от первого timestamp сида `--tail 50`: у долгоживущего
  лога начала может не быть → «?» (best-effort по task.md).
- «Скорость» TUI/plain печатает сырые числовые `llamacpp:*` — блок
  осознанно полупустой, пока EXP-007 не снимет полный список ключей
  (факт-база подтверждает 1 ключ; invent names запрещён).
- Форматы skipped/evicted не разбираются (в факт-базе их нет) —
  count-only по решению task.md OQ-4.
- faux `stat` passthrough требует реальный stat в /usr/bin или /bin —
  GNU-машины (целевые и ocbox) удовлетворяют.

## Out-of-scope proposals

- После EXP-007: подписи сырых ключей в «Скорости» (сейчас `имя=значение`)
  + заполнение ref_* в profiles.sh — точечные правки.
- Полировка геометрии TUI под узкие экраны (каркас hfctl-уровня) — этап 4.
- `--check-types`/usage-хвосты из бэклога STATE (не тронуты).

Скоуп соблюдён: status/--json, probe/bench/units/autostart, профильная
таблица (поля 1–9) — без изменений; EXP-007 не исполнялся; STATE/history/
FACTS не правил; коммитов нет.
