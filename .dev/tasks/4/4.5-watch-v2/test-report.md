# Test report: 4.5-watch-v2

Verdict: **PASS**
- Дата: 2026-11-21 · round: 1 (первичная приёмка)
- Проверял dev-report на слово — все команды прогнаны самостоятельно; базлайн
  снят с HEAD-копии (`git archive HEAD` → /tmp, рабочее дерево не тронуто).

## Internal checks

### Инфраструктурные (AGENTS.md «Internal checks» + тест-стратегия task.md)

| # | Проверка (команда) | Результат |
|---|---|---|
| 1 | `bash -n gfctl lib/*.sh` | OK, rc 0 |
| 2 | `bash -n tests/run_checks.sh` | OK, rc 0 |
| 3 | `python3 -m py_compile tpl/python/*.py` | OK (6 файлов), rc 0 |
| 4 | `bash tests/run_checks.sh` — полная батарея | **rc 0, ИТОГО PASS=381 FAIL=0** (строк `FAIL:` в выводе 0) |
| 5 | Базлайн HEAD (та же батарея на `git archive HEAD`) | rc 0, **PASS=367 FAIL=0** — совпадает с dev-report |
| 6 | `./gfctl` без аргументов (usage-гейт) | usage на stdout, **rc 1** ✓ |
| 7 | `./gfctl status --json` при недоступном порте | **корректный отказ**: rc 0, валидный JSON `"health":"не запущен"`, без краша (плюс §12 батареи PASS) |
| 8 | selfcheck watch-харнеса: `GFCTL_WATCH_SELFCHECK=1 python3 tpl/python/watch_tui.py` | **`selfcheck: 80/80 ok`, rc 0**; пин 80/80 закреплён в §37 батареи |
| 9 | `spec_validate` | valid: no issues ✓ |

### DoD brief → проверка → результат (все 8 пунктов)

| DoD | Проверка | Результат |
|---|---|---|
| 1 «Железо» | `watch_sysfs.py:52–83`: первая карта `vendor==0x1002` (card[0-9]* sorted); `temp_c = max(temps)/1000` ТОЛЬКО по `card*/device/hwmon/hwmon*/` ЭТОЙ карты (строки 70–81); busy из `device/gpu_busy_percent` (вне hwmon, :67); масштабы freq/1e6, power/1e6, VRAM/GTT Б; k10temp :86–95; цвета `temp_color` — жёлтый ≥80, красный ≥90 **по напечатанному** (selfcheck: 79.95→«80.0»→жёлтый, 89.96→«90.0»→красный). `grep read_first_temp` по репо — пусто (баг v1 устранён). Selfcheck: фейковое дерево card0=0x10de (skip), card1=0x1002 с ДВУМЯ hwmon (35875/41000 → ровно 41.0 MAX), per-field None, нет AMD → None | ✓ |
| 2 «Память» | `read_mem` (/proc/meminfo → GiB, round 1) + `mem_fill_color`: ≤0.1 red, ≤0.2 yellow, нет данных 0 (selfcheck 5/100, 10/100, 15/100, 20/100, 50/100, None, total=0); rows_memory RAM+bar(10)+VRAM/GTT | ✓ |
| 3 «Движок» | см. таблицу формул Round 2 ниже — все формулы в коде совпадают; роут из `load_completed` (parse_route_lines, последняя побеждает, модель с пробелами — selfcheck), режим `/ready` (collect :778–782) + configured (parse_configured_lines, \b-границы); спекуляция — отдельная строка `curses.A_BOLD` (watch_tui.py:1018, selfcheck rows_e[5][2]==A_BOLD) | ✓ |
| 4 «Логи» без -t + TZ | faux-ассерт батареи §37: `grep -c '^podman logs -t' FAUXLOG` = **0**; сид `--tail 50` присутствует; в коде LogStreamer оба вызова без `-t` (watch_tui.py:307, :324) + selfcheck шимом podman: `'-t' not in args`. TZ на рендере: буфер хранит сырые строки, `refresh_log_view` конвертирует каждую отрисовку (:804–808); §37: `[логи] HH:MM:SS [INFO] [cache]` и «исходная UTC-метка заменена (даты нет)»; selfcheck TZ=UTC (tzset) — точное время; строка без метки — как есть; невозможная дата → None | ✓ |
| 5 Свойства счётчиков | §37 3-тиковый прогон SEQ: tick2 (live, без done) — пульс decode +300 / prefill +512 / drafts 0; tick3 (done) — drafts +1000 (по Δdraft_tokens, не раундов), gen_last = gauge 53.3; средние точны по формуле на каждом тике (20.0 → 20.1 → 20.0 — live-крип вверх при живом числителе и замороженном знаменателе, отклонение developer принято Round 3 п.1); dead-тик → reset без ложных дельт; подпись «пульс завершений»/«НЕ скорость» — в коде блока «Скорость» и plain `(ток/тик)` | ✓ |
| 6 Батарея целая | п.4–5 таблицы выше: 367→381 (−11 старых watch + 25 новых §37), **все до-этапные секции зелёные** (детали в «Regression») | ✓ |
| 7 SPEC той же дельтой | `git diff .dev/SPEC.md`: §3 строка `watch` переписана под v2 (блоки/формулы/TZ/без -t), §8 ячейка watch («draft-приём» → вычисляемые); SPEC.md — не узел графа (нет frontmatter), `spec_validate` прогнан — valid | ✓ |
| 8 BLOCKED-EXTERNAL | **EXP-012-watch-v2-live.sh создан** (`.dev/external/`), НЕ запущен — D6: живые запуски только по GO, окно этапа 5. См. «External experiments» | отложен (по brief) |

### Соответствие кода формулам Round 2 (карта замен, точечно)

| Пункт Round 2 | Где в коде | Проверка | Результат |
|---|---|---|---|
| Кэш-эффект ≤100, знаменатель prompt+cached | watch_engine.py:107 `_pct(cached, prompt+cached)` | selfcheck: snap1 ровно 99.0; EXP-007 27044/(27044+93)=99.658≤100; инвариант ≤100 | ✓ |
| Acceptance по draft_tokens (не раунды) | :110 `_pct(K_ACC, K_DRAFT_TOK)`; K_ROUNDS объявлен (:31) и в формулах не участвует | selfcheck: snap1 ровно 60.0 **и** `!= 60000/5000×100`; EXP-007 11/30=36.67; батарея: «спек 60.0%» | ✓ |
| Draft-пульс = Δdraft_tokens | Deltas.update :149–150 (K_DRAFT_TOK) | selfcheck tick3: drafts +1000 (токены); батарея: `drafts +1000` | ✓ |
| Prefill = prompt/prompt_seconds_total | :103 `_div(prompt, K_PROMPT_S)`; несуществующее имя ТЗ не используется | selfcheck: snap1 ровно 100.0; EXP-007 146.98 | ✓ |
| Speed-gauge «последний запрос» | `gen_last = K_GEN_LAST` (:102), `prefill_last = K_PREFILL_LAST` (:104); Δ/Δ в Deltas **удалён** | selfcheck: gauge passthrough + `'gen_last' not in d2`; батарея t1 `gen 20.0/21.4 … prefill 100.0/98.7`, t3 gauge 53.3 | ✓ |
| Token-счётчики live: snap2-пульс | LIVE-ключи только в Deltas (prefill/decode); drafts — done-only | selfcheck tick2: `{decode:300, prefill:512, drafts:0}`; батарея tick2: `пульс: decode +300 prefill +512 drafts +0` | ✓ |
| device_lost красный | rows_hardware :970–971 `C_RED if (lost or 0) > 0`; отсутствует → `?` (fmti) | selfcheck: lost>0 → C_RED; plain `[железо] … lost 0`; батарея «lost 0» | ✓ |
| lookup скрыт при нулях | rows_engine :1029–1033 + plain :221–226 — строка только при `lt>0 or la>0`; отсутствие ключей = 0 | selfcheck: скрыт при нулях/отсутствии, виден `lookup 200/250 (80.0%)`; батарея: `! grep -qi lookup` | ✓ |
| prompt_state не читаются (hard rule) | engine_stats/рендер ключей не упоминают; parse_metrics нейтрален (пропускает как прочие) | selfcheck: fixture `gufo_prompt_state_budget_bytes 123` → в выводе watch «budget» нет; батарея §37 тот же ассерт | ✓ |
| TZ-конверсия на рендере | `refresh_log_view` :804–808 конвертирует сырой буфер при каждой отрисовке; `log_line_local` :192–201 | selfcheck TZ=UTC: точное HH:MM:SS; пауза/перерисовка детерминированы (конверсия не в коллекторе) | ✓ |
| Логи без -t (faux-ассерт) | watch_tui.py:307 (сид), :324 (live) | §37: `grep -c '^podman logs -t'` = 0 + сид `--tail 50` на месте; selfcheck-шим: `-t` нет в args | ✓ |

### Фикстуры ↔ Round 2 (числа сойдены)

`snap1`: 10000/990000/100/50000/2500/262144/раунды 5000/draft_tokens 100000/accepted 60000/kv 0.12/0/0/gauge 98.7 и 21.4/lost 0/lookup 0/0 — все 17 ключей эмиттера ✓. `snap2`: +512/+512/+300, секундные/раунды/draft_tokens/accepted/пик заморожены ✓. `snap3`: prompt_s 105.2, predicted_s 2515, раунды 5060, draft_tokens 101000, accepted 60640 (60.04%), пик 27155, kv 0.34, gauge 53.3, token-счётчики стоят ✓. Арифметика: кэш 99.0→98.95 (≤100), gen 20.0→20.12 («20.1»)→20.0 (50300/2515), acceptance 60.0→60.04 — батарейные ассерты бьют точно в эти значения.

## Failures (FAIL)

Нет. Ни одного красного ассерта: батарея 381/0, selfcheck 80/80, lint/compile чисто, usage-гейт и dead-port-гейт AGENTS зелёные.

## External experiments

| EXP-id | DoD | Статус |
|---|---|---|
| **EXP-012-watch-v2-live** (`.dev/external/EXP-012-watch-v2-live.sh`) | DoD 8 (живой прогон) | **created, ответа нет — окно этапа 5** (D6: живые запуски только по GO). Скрипт не запускался, bash -n OK |

**External experiments: created, ответа нет (окно этапа 5).** DoD п.8 закрыт
отложенным прогоном (grounding: brief п.8 — «BLOCKED-EXTERNAL, не блокирует
закрытие подэтапа, уходит в окно этапа 5»). EXP-012 покрывает: /metrics 200 +
rc 0 plain-стрима, движение счётчиков между тиками (bench в фоне),
температуры vs hwmon/sensors (±2 °C), TZ vs `date` хоста (секунда-в-секунду),
TUI на SSH-TTY (q/+/-/p, подтверждение оператора), все 5 plain-блоков.
Нумерация per-project gfctl: EXP-001…011 заняты; EXP-012/013 llm-lab — другая
очередь, не смешана.

## Regression (каждая секция, полный прогон)

- Батарея: HEAD **367/0** (48 секций) → рабочий **381/0** (48 секций); rc 0 в обоих.
- Заголовки секций диффом: **идентичны все, кроме заголовка §37** (переименован под v2).
- §37: 11 ассертов → 25 ассертов; арифметика 367 − 11 + 25 = 381 ✓ (сходится с dev-report).
- `git diff tests/run_checks.sh` — ровно **3 хунка**: шов `GFCTL_FAUX_METRICS_SEQ` (комментарий faux-bin + ветка в faux curl; без переменной — старое поведение, соседние тесты не менялись) + переписанная §37. Иного в батарее нет.
- Shell-слой: `git diff lib/ gfctl` — **пуст** (cmd_watch/env не менялись, как в Design).
- «Fails as it should»: мёртвый сервер — ровно 3 строки «недоступен» на 3 тика, rc 0, без traceback (§37); деление на 0 → None → '-'/'?' (selfcheck); отрицательный Δ (recreate) → None + reset; update(None) → сброс без ложных дельт; невозможная дата лога → None (время не выдумывается); TERM кривой → фолбэк plain (каркас v1, selfcheck).

## Non-critical notes (reviewer backlog, не блокируют)

1. `fmt_uptime` (watch_tui.py:170–182) — мёртвый код: uptime убран из v2 по Round 3 п.2, функция осталась без вызовов. Удалить в следующей дельте или при чистке.
2. Базлайн 367 ≠ 363 из task.md — батарея доросла чужими дельтами до правок; инвариант «до-этапные зелёные» соблюдён и подтверждён независимым прогоном HEAD-копии (совпадает с dev-report).
3. Инвариант Round 3 «средняя не падает в live-тике» покрыт точными формульными пинами на каждом тике (20.0 → 20.1 → 20.0), отдельного монотонного ассерта нет — поведение полностью определено формулой, риска не вижу.
