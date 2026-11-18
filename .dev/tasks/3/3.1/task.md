# Task: 3.1 agent-check + cache + watch          Design: architect

## Scope and DoD

**Цель** (из brief): снять последние три die-заглушки — `gfctl agent-check`
(SPEC §7), `gfctl cache [--verify]` (SPEC §3), `gfctl watch [--interval N]`
(SPEC §3/§8); EXP-заготовка окна этапа 3.

DoD-чеклист (проверяет tester/reviewer):
- [ ] `agent-check`: 4 проверки реализованы (сессия 15 ходов / follow-up-лестница
      5k/25k/100k / [док 25k][q1→q2] / рестарт-restore); референсы per профиль
      (таблица референсов в `lib/profiles.sh`); сравнение — ЧИСТАЯ функция
      `cmp_ref` (±25% → WARN); сводка PASS/WARN/FAIL; rc: 0 при all-PASS и при
      WARN, 1 при FAIL (WARN ≠ FAIL); предупреждение перед рестартом.
- [ ] `cache`: сводка из лога (`event=configured`: capacity/disk/ram_cache/
      automatic + счётчики skipped/evicted) + `/metrics`
      `llamacpp:prompt_tokens_cached_total` (best-effort, не-фатально);
      `--verify`: контрольный follow-up (reuse из `timings.component_cache`)
      + рестарт-проба через `container_up` + tmpfs-детект (WARN).
- [ ] `watch`: TTY-TUI и не-TTY-стрим; клавиши q/+/-/p; мёртвый сервер — одна
      строка «недоступен» на тик без спама; интервал `--interval N` (целое ≥1,
      дефолт 2).
- [ ] Заглушки сняты РОВНО у agent-check/cache/watch: роутер (`gfctl:207`)
      → cmd_*; usage-строки без пометок «[этап 3]»; остальные команды не
      затронуты; internal checks зелёные; регресс 1.1+1.2+2.1 цел (225 ассертов).
- [ ] EXP-007 заготовка: `.dev/external/EXP-007-agentcheck.sh` (заголовок:
      цель/пре-реквизиты/запуск/PASS-критерии; agent-check на flash-multi
      2×262144 + 27b-single evo; сбор сырых llamacpp:* ключей и образцов
      skipped/evicted-строк) — В ОЧЕРЕДИ, не исполняется (D6).

**Out of scope** (не делать): изменения status/--json-схемы; probe/bench/
check-types/units/autostart; исполнение EXP-007 и заполнение референсов
(после окна); README (этап 4); `--with-vision`, 8–16 потоков; изменения
профильной таблицы (поля 1–9 не трогаем — референсы отдельным слоем).

## Design

### 0. Протокол агентских запросов — единый конверт (факт-база окон)

Все HTTP agent-check/cache --verify — POST `/v1/chat/completions`, тело:
`{"model": ROUTE_MODEL, "messages": [...], "max_tokens": N, "temperature": 0,
"reasoning_effort": "none"}`. Reasoning off = поле запроса
`reasoning_effort: "none"` (протокол окон FX/CX: `fx_cache_tests.py`,
`agent_bench.py` — оба клиента окон так работают; НЕ `/no_think` и НЕ
`chat_template_kwargs`). Greedy = `temperature: 0`. Ответ gufo несёт
`timings` (подтверждено окнами): `prompt_ms`, `predicted_ms`,
`predicted_per_second`, `cache_n`, `component_cache.{reuse, prefilled_tokens}`
— все метрики follow-up/restore читаются ИЗ ТЕЛА ОТВЕТА, парсинг логов для
таймингов не нужен. Значения `reuse`: `none` | `live` | `disk` (наблюдено в
EXP-IX-W4/EXP-FX).

Детерминированный генератор документа (~6.6k и ~25k ток) — текст-юнит × N
повторов (юнит ≈25 ток, ×40 на 1k — формула окон). Один юнит-текст в коде,
без внешних файлов: `tpl/agent/*.txt` НЕ заводим.

### 1. Референсы — `lib/profiles.sh` (скалярные переменные + `ref_get`)

НЕ 10-е поле таблицы (референс многозначный: сессия/follow-up/restore) и НЕ
ассоциативные массивы (bash4-зависимость ради 5 констант). Слой скаляров рядом
с таблицей — тот же паттерн indirect-раскрытия, что `profile_field`:

```bash
# Референсы агентских проверок (SPEC §5; секунды). '' = референс не снят
# (WARN «эталон не снят», сравнение пропускается). Числа — AGENT-CONFIGS п.3;
# flash-multi/27b-multi — после EXP-007.
ref_27b_single_session="23.8"     # сессия 15 ходов
ref_27b_single_followup="1.7"     # follow-up 25k, ≤
ref_27b_single_restore="0.81"     # рестарт-restore @27k
# ref_<профиль>_docq — НЕ снят ни для одного профиля (AGENT-CONFIGS имеет
# только halogen-число) — до EXP-007 всегда WARN.
```

`ref_get <профиль> <метрика>` → печать значения или '' (rc 0 всегда;
`profile_<профиль>`-стиль имён: дефисы→подчёркивания, как в profile_field).
Док-метрика: session/followup/restore/docq.

### 2. Чистое сравнение — `cmp_ref` в `lib/agentcheck.sh`

```bash
cmp_ref <метка> <measured_s> <ref_s>   # → строка «PASS|WARN: …» в stdout
```
- ref пуст → `WARN: <метка> X.Xs — референс не снят (EXP-007)`;
- measured ≤ ref × 1.25 → `PASS: <метка> X.Xs (референс Y.Ys)`;
- иначе → `WARN: <метка> X.Xs — регрессия >25% к Y.Ys (проверь --cache-ram-bytes/--cache-disk)` —
  подсказка причины по SPEC §7 п.5 (только у follow-up/restore-строк; метку
  подсказки выбирает вызывающий — третий аргумент-вариант `hint`).
- float-сравнение через awk; ФЕЙЛ-ветки (запрос не ответил) — НЕ cmp_ref:
  структурный провал ставит FAIL вызывающий (python rc≠0 / пустой measured).
  Функция чистая: тестируется в батарее без HTTP (§Test 3).

### 3. `gfctl agent-check` — новый модуль `lib/agentcheck.sh` + `tpl/python/agent_check.py`

Разделение: HTTP/математика — python (stdlib, один файл = одна роль), оркестрация/референсы/rc — bash (faux-bin-тестируемо).

**bash `cmd_agentcheck`** (порядок фиксированный):
1. Гейты: `container_state = running` → `port_open` → `parse_route`
   (ROUTE_MODEL пуст → die, как в smoke).
2. `warn "agent-check: рестарт-restore ПЕРЕЗАПУСКАЕТ контейнер — активные сессии сервера будут потеряны"` (без ask — OQ-3).
3. `python3 tpl/python/agent_check.py stage1` (curl-независимый python
   urllib; печатает строки `CHECK <имя> <key>=<val>…`; rc≠0 → die).
   stage1 = (а) сессия 15 ходов, (б) лестница 5k/25k/100k, (в) docq,
   (г)-turn1 (25k-doc разговор) — состояние (г) сохраняет в
   `$STACK_DIR/logs/agent-check-restore.json` (полные messages + ответ).
4. Парсинг CHECK-строк (grep/cut) → cmp_ref: сессия vs `ref_get P session`;
   follow-up **25k** vs `ref_get P followup` (5k/100k — печать числа без
   сравнения); docq vs `ref_get P docq` (сейчас всегда WARN «не снят»).
5. `container_up "$(cur_profile)"` (ТОТ ЖЕ единственный путь подъёма, что
   use/on — рестарт восстанавливает КАНОН; лог «рестарт контейнера…»)
   → `wait_health 180`.
6. `python3 tpl/python/agent_check.py stage2` → restore-wall → cmp_ref vs
   `ref_get P restore`; вердикт restore: wall — cmp_ref, ДОПОЛНИТЕЛЬНО
   reuse из CHECK-строки: `reuse=live|disk` → ok, `reuse=none` → **FAIL**
   «disk-restore не сработал».
7. Сводка: `AGENT-CHECK: PASS=N WARN=M FAIL=K` + rc (K>0 → 1, иначе 0).
   Структурный FAIL в любом чеке (python rc≠0) → die до сводки (rc 1).

**python `agent_check.py`** (режимы аргументом; env: GFCTL_WATCH-порт НЕ
использует — port из argv/env GFCTL_AGENT_PORT, model из argv): порт/модель
передаёт bash (уже в ROUTE_*); timeout каждого запроса 1200 c (окна);
`timings` отсутствует в ответе → структурный FAIL (rc 1, stderr-причина).
Промпты — литералы файла (порт протокола окон; F12: фикстура bench к
agent-check отношения не имеет). Сессия: doc 6.6k (16 фактов ×11 ≈ 35k симв.)
+ system + 15 Q→A (история растёт), max_tokens 128.

**Диспетчер**: роутер `agent-check) cmd_agentcheck "$@" ;;` (из die-ветки,
ветка остаётся для watch|cache до их снятия — все три снимаются в этом
сабстэдже, die-ветка исчезает); usage: снять «[этап 3]» у трёх строк;
комментарий роутера обновить.

### 4. `gfctl cache [--verify]` — `cmd_cache` в `lib/commands.sh`

- `parse_configured` — ЧИСТАЯ функция (stdin = текст лога; пишет глобалы
  `CC_CAPACITY/CC_DISK/CC_RAMCACHE/CC_AUTOMATIC/CC_SESSIONS`; '' = нет):
  последняя строка `event=configured`, поля grep -oE + cut (паттерн
  parse_route). Формат — живой лог FX-W1b (EXP-005-машина):
  `[cache] schema=component-cache-v1 event=configured sessions=1 …
  capacity_bytes=4294967296 … automatic_bytes=15904702464 …
  disk_capacity_bytes=68719476736 … ram_cache=on disk_backing_bytes=0`.
  Отсутствие строки — НОРМА (кэш не настроен): rc 0, глобалы ''.
- Сводка (rc 0 всегда, как doctor): профиль/каталог кэша + `du -sb`
  (как status) + строка из parse_configured (GiB через awk) + счётчики
  `event=skipped` / `event=evict*` — grep -c БЕЗ разбора формата (в факт-базе
  форматов нет — считаем вхождения; EXP-007 соберёт образцы) + `/metrics`:
  curl `-m 5 …/metrics` → строка `llamacpp:prompt_tokens_cached_total <N>`
  (ключ подтверждён FX-W5; отсутствие ключа/эндпоинта → «?», НЕ фатально).
- `--verify` (порядок): (1) контрольный follow-up: doc 5k → q1 → тот же
  разговор + follow-up; вердикт по `timings.component_cache.reuse`:
  `live|disk` → PASS, `none` → **FAIL** «follow-up не переиспользовал кэш —
  проверь --cache-ram-bytes» (rc 1); (2) tmpfs-детект: `fs_type` — обёртка
  `stat -f -c %T "$STACK_DIR/cache/<профиль>"`; `tmpfs` → WARN «кэш-каталог
  на tmpfs — disk-тир переживает только до ребута»; (3) рестарт-проба:
  warn «рестарт убивает активные сессии» → `container_up "$(cur_profile)"` →
  `wait_health 180` → ход того же разговора (состояние в
  `$STACK_DIR/logs/cache-verify.json`, как agent-check): reuse `disk|live` →
  PASS «disk-restore работает (X.Xs)», `none` → FAIL. Человекочитаемые строки
  каждого шага. Грамматика: лишние аргументы → die (по образцу bench).
- faux-bin-шов: `fs_type` зовёт `stat` из PATH → батарея подкладывает faux
  stat (§Test 4).

### 5. `gfctl watch [--interval N]` — `cmd_watch` в `lib/commands.sh` + `tpl/python/watch_tui.py`

- bash — только разбор `--interval N|N=` (дефолт 2; isint ≥1, иначе die —
  паттерн hfctl cmd_watch 1:1) и `exec python3 tpl/python/watch_tui.py` с
  env `GFCTL_WATCH_PORT/INTERVAL/CONTAINER` (argv не используется — как
  hfctl; rc = rc python).
- python — НОВЫЙ файл, адаптация каркаса hfctl `tpl/python/watch_tui.py`
  (SPEC §8 «переиспользуем TUI-каркас»; у каркаса уже есть: два рендерера
  TUI-curses/plain по `sys.stdout.isatty()`, env-входы, deque-лог 500 строк,
  поток `podman logs --tail 50 -f`, парсер Prometheus `parse_metrics`,
  read_mem/hwmon-температуры, клавиши q/+/−/p, plain fallback без curses).
  Перестройка слоя данных (вот РАЗНИЦА движков):
  - gufo НЕ имеет /stats — убрать stats-поллер; `/metrics` — ЕДИНСТВЕННЫЙ
    движковый источник: печатаются СЫРЫЕ ключи `llamacpp:*` (best-effort:
   Confirmed-факт-базой является только `llamacpp:prompt_tokens_cached_total`;
    выдумывать имена `predict_per_second`/`queue` ЗАПРЕЩЕНО — блок «Скорость»
    показывает сырые ключи, чего нет — «?»; факт-база пополнится EXP-007);
  - uptime/model — из сида логов: model= из последней `load_completed`
    (то же правило «до sessions=», что parse_route), uptime — первый
    timestamp лога; недоступно → «?»;
  - блоки (SPEC §3): «Движок» (model, uptime, cached_total, сырые ключи),
    «Скорость» (сырые llamacpp:* числовые), «Память» (MemTotal/
    MemAvailable /proc/meminfo + первая `temp*_input` /sys/class/hwmon),
    «Логи» (хвост deque). Высота блоков = наполнение, остаток — «Логи»
    (полировка hfctl).
  - мёртвый сервер: на тик РОВНО одна строка `недоступен` (plain) / блок «?»
    (TUI), затем сон интервала; без traceback-спама (urllib-ошибка → значение
    None, не краш).
  - батарейный шов: env `GFCTL_WATCH_TICKS` (0 = бесконечно, дефолт; N>0 —
    N тиков и выход) — иначе батарея не может запустить стрим; интервал <0.05
    (только через env напрямую) — без сна в тесте.
- Клавиши TUI: `q/Q` — выход rc 0; `+`/`-` — интервал ±1 с (min 1); `p` —
  пауза live-лога (самодостаточная подсказка «логи: live, пауза: p»).

### 6. Поток данных / краевые случаи (сводно)

- ROUTE_MODEL с пробелами — везде идёт как одно значение argv/env/python
  (не встраивается в JSON руками — json.dumps в python; в bash только ROUTE_*
  глобалы после parse_route).
- Первый запрос после recreate может быть 5xx (F15): agent-check/cache --verify
  делают ОДИН ретрай первого запроса (тот же паттерн smoke, env
  GFCTL_SMOKE_RETRY_S).
- `container_up` в agent-check/cache --verify поднимает канон ТЕКУЩЕГО
  профиля: если сервер запускали мимо gfctl с другим контекстом — рестарт
  вернёт канон (осознанно: единственный путь подъёма; подсказка в warn).
- Перезапуск убивает пользовательские сессии — только два явных места
  (agent-check, cache --verify), оба с предупреждением до podman-rm.
- Все записи на диск — только `$STACK_DIR/logs/*.json` (состояние
  restore/follow-up); удаляются после использования; отказ записи → die.

## Test strategy

| DoD | internal check (батарея, faux-bin) | external (EXP) |
|---|---|---|
| agent-check 4 проверки | §A: детерминированный прогон `gf 'cmd_agentcheck'` (faux curl с `timings`+`component_cache`, podman-лог LOGOK): ровно 25 chat-POST (15+6+2+2), 4 CHECK-строки, сводка, rc 0; порядок «warn-рестарт → podman rm» по FAUXLOG | EXP-007: живые тайминги, reuse=disk после рестарта |
| cmp_ref (±25%) | §B чистая функция: measured 20/ref 23.8→PASS; 28→PASS (≤29.75); 30→WARN; ref=''→WARN «не снят»; ветка подсказки — хвост строки | — |
| refs per профиль | §B: ref_get 27b-single/session=23.8, followup=1.7, restore=0.81; flash-multi/27b-multi/docq — '' | EXP-007 заполняет |
| структурный FAIL | §A2: curl FAILALL → die rc 1 до сводки; timings нет в ответе (faux-флаг) → rc 1 | — |
| cache сводка | §C: фикстурный лог с ДВУМЯ configured (последняя побеждает) + skipped/evicted → parse_configured глобалы (capacity/disk/ram_cache/automatic); строка сводки; /metrics через faux curl → cached_total; metrics отказ → «?», rc 0 | EXP-007: форматы skipped/evicted |
| cache --verify | §C2: reuse=live→PASS-строка; reuse=none→FAIL rc 1; рестарт: warn в FAUXLOG раньше `podman rm -f`; второй чанк curl → reuse=disk→PASS | EXP-007: живой disk-restore |
| tmpfs-детект | §C3: faux-bin `stat` (7-я заглушка) `GFCTL_FAUX_STAT_FSTYPE=tmpfs` → WARN; ext4 → нет WARN | живой stat на машине |
| watch не-TTY | §D: `GFCTL_WATCH_TICKS=1` + faux curl: один срез блоков; мёртвый сервер (FAILALL, TICKS=3) → ровно 3 строки «недоступен», без stderr-спама; счётчик /metrics-вызовов = тикам | PLAN-DoD: TUI на SSH-TTY (клавиши) — окно |
| TUI-ветка | §D2: python --selfcheck-режим (env GFCTL_WATCH_SELFCHECK=1, как у hfctl-каркаса) — парсер/рендер-скелет без curses-экрана | TUI q/+/-/p — EXP |
| заглушки сняты ровно | §2 замещается по п.0-прецеденту: watch/cache/agent-check → цикл «не-заглушка» (timeout, без «появится в сабстэдже»); usage без «[этап 3]» у трёх строк; остальные usage-строки байт-в-байт | — |
| регресс | полный прогон батареи 1.1+1.2+2.1 зелёный (225) + bash -n/py_compile | — |

Тайминги в батарее НЕ ассертятся (машино-зависимы) — только вердикт-строки,
структура и счётчики вызовов. Faux curl расширяется: ветка `/metrics`
(канонический текст с `llamacpp:prompt_tokens_cached_total 539` + файловый
оверрайд `GFCTL_FAUX_METRICS`), флаг `GFCTL_FAUX_CURL_TIMINGS=1` добавляет
в chat-ответ `"timings":{"prompt_ms":…,"component_cache":{"reuse":"…"}}`
(значение reuse сценарится `GFCTL_FAUX_CURL_REUSE`, счётчик тот же
GFCTL_FAUX_CNT.curl).

## Risks and rollback

- **watch_tui.py — самый крупный файл сабстэджа** (адаптация ~1200-строчного
  каркаса): риск дрейфа. Смягчение: менять только слой данных (убрать /stats,
  добавить /metrics-ключи/uptime-парс), рендер/клавиши/поток логов — как есть;
  selfcheck-режим сохраняем. Откат: файл самодостаточен, revert одного коммита.
- **Факт-база /metrics тонка** (подтверждён 1 ключ): блок «Скорость» может
  оказаться полупустым на живом сервере. Это best-effort по дизайну (сырые
  ключи), не блокер; EXP-007 фиксирует полный список → тогда точечная правка
  подписей. Не изобретать имена ключей.
- **Контракт `timings` в ответе** — наблюдён в окнах, но не зафиксирован в
  доках gufo: если ревизия уберёт поле, agent-check деградирует в структурный
  FAIL с явной причиной (не тихо). Смягчение: сообщение «timings отсутствует —
  проверь ревизию gufo», EXP-007 подтверждает на живом.
- **Рестарт в agent-check/cache --verify убивает сессии** — предупреждение до
  recreate (проверяется батареей по порядку FAUXLOG); другого пути проверить
  cache-disk нет (F17).
- **Долгий agent-check на регрессировавшем движке**: каждый запрос ограничен
  -m 1200; шагов 25 → худший бюджет десятки минут при мёртвом-но-отвечающем
  сервере. Приемлемо для явной диагностической команды; прогресс печатается
  по ходам (сессия — turn-строки python), не hang.
- **Откат сабстэджа**: git revert до начала 3.1; заглушки возвращаются
  изолированно, этапы 1–2 не затронуты (робер/usage-правки локальны).

## References

- SPEC §7 (протокол agent-check), §3 (строки cache/watch), §5 (референсы
  27b-single: 23.8 с / ≤1.7 с / 0.81 с @27k; мульти — «снять заново»), §8
  (watch: /metrics llamacpp:*, TUI-каркас hfctl, логи draft).
- PLAN этап 3 (DoD: 4 пункта agent-check; tmpfs-WARN; TUI/стрим/мёртвый).
- FACTS: F12 (фикстура ≠ agent-check), F15 (ретрай первого), F17
  (restore 0.35–0.81 живой), F18/F20 (парные референсы ≠ bench, не смешивать;
  имена моделей с пробелами), F2/F9 (контекст рестартов).
- DECISIONS: D4/D5 (профили), D6 (окна по GO — EXP-007 не исполнять).
- Протокол окон (источник конверта запросов и метрик из тела ответа):
  `llm-lab/.local-analysis/dl/fx_cache_tests.py`, `llm-lab/flow/gufo-27b-evo/
  agent_bench.py`; live-форматы: `.local-analysis/gufo-flash-next-faex/
  EXP-FX-W1b-up-q4xl.result.txt` (configured-строка), `EXP-FX-W5-conc2.result.txt`
  (/metrics ключ); AGENT-CONFIGS п.1/3/4/6 (референсы, halogen-docq — вне gufo).
- Каркас watch: `/workspace/hfctl/tpl/python/watch_tui.py` + `cmd_watch`
  (hfctl/lib/commands.sh:265). EXP-004/005 result-файлы (живые роуты мульти).
- Код: lib/health.sh (parse_route/smoke — переиспользование), lib/commands.sh
  (bench_request/bench — HTTP-паттерн, die-грамматика), lib/profiles.sh
  (ref-слой рядом с таблицей), lib/serve.sh (container_up), tests/run_checks.sh
  (faux-bin, frun/gf).

## Open questions

1. **Референсы flash-multi/27b-multi unset → WARN или FAIL?**
   Рекомендация: **WARN «референс не снят»** (реализовано в Design): эталон
   ещё не снят (EXP-007 впереди), FAIL блокировал бы agent-check на всех
   мульти-профилях до окна; регрессия-vs-неснятый-эталон — разные ситуации.
   Не блокирует код (константа вердикта).
2. **/metrics best-effort**: подтверждён только
   `llamacpp:prompt_tokens_cached_total`; остальные ключи gufo не
   документированы в факт-базе. Рекомендация: cache — только подтверждённый
   ключ (отсутствие → «?», не-фатально); watch — сырые llamacpp:* без
   выдуманных подписей; полный список снимает EXP-007. Альтернатива (не
   рекомендую): блокировать cache/watch до снятия факт-базы — теряем окно.
3. **Рестарт-restore в agent-check/cache --verify убивает активные сессии —
   достаточно ли предупреждения (без ask)?** Рекомендация: **да** — обе
   команды явные диагностические; ask() ломал бы не-TTY прогоны EXP-007
   (авто-нет); риск тот же класс, что у `use` (recreate без вопроса).
   EXP-протокол окон всё равно гасит соседей по GO.
4. *(не блокирует)* Форматы строк `event=skipped`/`event=evicted` в логе gufo
   в факт-базе отсутствуют — считаем вхождения grep -c без разбора; EXP-007
   добавляет сбор образцов (в заготовку включено).
