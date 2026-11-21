# Task: 4.5-watch-v2 (переработка watch-дашборда по ТЗ 4.5)            Design: architect

## Scope and DoD

Замена watch v1 на v2 по зафиксированному ТЗ `tasks/4/4.5-watch-v2-decision.md`
(единственный носитель дизайна). Дельта — python-слой + батарея + SPEC; shell-слой
НЕ меняется (см. Design → «Граница shell/python»).

DoD (из brief, единственный носитель — brief.md; здесь — рабочая выжимка):

1. «Железо»: первая карта vendor 0x1002 в `/sys/class/drm/card*`; `temp_c` = MAX
   по всем `temp1_input` ЭТОЙ карты (баг v1 `read_first_temp` устранён);
   `sclk_mhz`, `power_w`, `busy_pct` (card*/device/gpu_busy_percent), VRAM/GTT
   (Б→GiB); CPU `Tctl` (k10temp). Цвета: жёлтый 80–89 °C, красный ≥90.
2. «Память»: RAM MemTotal/MemAvailable (`/proc/meminfo`, GiB) + VRAM/GTT,
   цвет по заполнению RAM.
3. «Движок» — вычисляемые из кумулятивных `/metrics` (формулы — Design §«Движок»);
   генерация средняя/последняя, prefill, кэш-эффект %, спекуляция accepted %
   (выделенная строка) + draft sparkline, KV % и пик, очередь, счётчики всего,
   роут (лог `load_completed`) / режим (`/ready`) / cache-«configured» (лог).
4. «Логи»: `podman logs` БЕЗ `-t` (время в строках движка — факт EXP-005/006:
   `2026-11-17 23:28:03 [INFO] [gpu] event=…`), TZ-конверсия UTC→локальный пояс
   в слое watch; TUI + plain — оба режима.
5. Свойства счётчиков учтены: обновление ТОЛЬКО на done → средние в idle
   стабильны; Δ за тик = «пульс завершений» (sparkline), НЕ скорость.
6. Батарея: фикстуры-снапшоты /metrics (стабильный + live-дельты) зелёные;
   все существующие ассерты зелёные (базлайн: `bash tests/run_checks.sh` на HEAD
   до правок — на момент написания 363/0, в brief указано 362 до ассерта 4.4);
   `bash -n gfctl lib/*.sh`; `python3 -m py_compile tpl/python/*.py`.
7. SPEC §3 (строка `watch`) обновлён той же дельтой (+ ячейка `watch` в §8 —
   там v1-формулировка «логи (draft-приём)», в v2 draft-приём из /metrics);
   `spec_validate` прогнан (SPEC.md — не узел графа, без frontmatter — правка
   обычным edit; spec_validate — формальность протокола, граф пуст).
8. BLOCKED-EXTERNAL (в окно этапа 5, не блокирует закрытие подэтапа): живой
   прогон — счётчики движутся, отображение 200, сверка температур с
   `sensors`/hwmon, сверка TZ-конверсии с `date` хоста.

**Out of scope (явно):**
- живой прогон на машинах — только в окно этапа 5 по D6 (D2: порт 8080 — не меняется);
- контейнер/TZ gufo не трогаем (конверсия только в слое watch);
- bench, agent-check, smoke, cache, юниты systemd, профильная таблица — не трогаются;
- F20 (BF16=30, display-имена) — не относится к watch, не трогать;
- CUDA/NVML, альтернативные GPU-vendor, swap-строка памяти (у hfctl есть, в ТЗ
  gfctl не заказано) — идеи в dev-report «Out-of-scope proposals»;
- полный переход диспетчера на питон — отдельный этап (4.4-decision, триггеры не сработали).

## Design

### Граница shell/python (принцип 4.4-decision)

**Shell-слой: ноль изменений.** `cmd_watch` (lib/commands.sh:1078) уже тонкий:
разбор `--interval` → env `GFCTL_WATCH_PORT/INTERVAL/CONTAINER` → `exec python3
tpl/python/watch_tui.py`. Эти env достаточны для v2; argv/python не получает —
сохранить. Комментарий cmd_watch упоминание «podman logs» не содержит — правок нет.
Всё data-heavy — только python.

### Файлы и ответственности (tpl/python/, один файл = одна роль)

| Файл | Роль | Статус |
|---|---|---|
| `tpl/python/watch_sysfs.py` | НОВЫЙ. Системные источники «Железо»/«Память»: GPU-карта AMD, CPU Tctl, RAM | new |
| `tpl/python/watch_engine.py` | НОВЫЙ. Движковые данные: парсер /metrics, формулы-статы, дельты-пульс, парсеры лога (роут/configured/uptime), TZ-конверсия, sparkline | new |
| `tpl/python/watch_tui.py` | Харнес + рендеры (единственный коллектор-цикл, TUI/plain, LogStreamer, selfcheck, main). Импортирует два модуля (script-dir уже в sys.path) | rewrite v1→v2 |

#### watch_sysfs.py — интерфейсы (перенос hfctl 1:1, файл-эталон
`/workspace/hfctl/tpl/python/watch_tui.py:172–255`)

```python
def read_gpu(base='/sys/class/drm'):
    """@returns dict|None  # первая карта с device/vendor == '0x1002'
    (card[0-9]* sorted); карта не найдена → None.
    Ключи (каждый отсутствующий файл → None в СВОЁМ поле):
      temp_c   — MAX temp1_input/1000 по всем card*/device/hwmon/hwmon*/
                 ЭТОЙ карты (миллиградусы; ЛОВУШКА v1 устранена: фильтр по
                 карте обязателен — иначе читается CPU k10temp);
      sclk_mhz — freq1_input/1e6 (Гц→MHz);
      power_w  — power1_input/1e6 (мкВт→W);
      busy_pct — card*/device/gpu_busy_percent (НЕ в hwmon-каталоге);
      vram_used, gtt_used — mem_info_vram_used / mem_info_gtt_used, БАЙТЫ
                 (в GiB переводит рендер)."""
def read_cpu_temp(base='/sys/class/hwmon'):
    """@returns float|None  # Tctl °C: первый hwmon с name=='k10temp',
    temp1_input/1000, round 1 знак; нет датчика → None"""
def read_mem(path='/proc/meminfo'):
    """@returns dict  # {'available_gib','total_gib'} GiB round 1 (v1 1:1);
    нет поля → None"""
```

#### watch_engine.py — интерфейсы

```python
def parse_metrics(text):            # v1 1:1 (watch_tui.py:131): dict name→float;
                                    # '#…' и *_bucket долой, labels {…} сняты

def engine_stats(m):
    """@param m: dict|None          # parse_metrics /metrics этого тика
    @returns dict|None              # m is None/пуст → None (dead-тик).
    КЛЮЧИ (значение None — нет ключа или деление на 0):
      gen_avg      = tokens_predicted_total / tokens_predicted_seconds_total
                     [tok/s] — средняя накопленная (idle-стабильна);
                     кросс-чек в selfcheck: == predicted_tokens_seconds
                     (движковый gauge; EXP-007: 18/0.8935=20.144 ✓);
      prefill_avg  = prompt_tokens_total / prompt_seconds_total [tok/s]
                     [ОТКРЫТЫЙ ВОПРОС OQ-1: ТЗ называет знаменатель
                     prompt_tokens_seconds_total — имени НЕТ в факт-базе;
                     реализация ждёт ответа оркестратора, до ответа код не
                     пишется в этой строке];
                     кросс-чек: == prompt_tokens_seconds (93/0.6327=146.98 ✓);
      cache_pct    = prompt_tokens_cached_total / prompt_tokens_total × 100;
      spec_pct     = spec_decode_num_accepted_tokens_total /
                     spec_decode_num_drafts_total × 100;
      kv_pct       = kv_cache_usage_ratio × 100 (мгновенный gauge);
      kv_peak      = n_tokens_max (токенов);
      q_proc, q_def = requests_processing / requests_deferred (шт);
      tok_prompt, tok_pred, tok_cached — счётчики всего [шт].
    [ОТКРЫТЫЙ ВОПРОС OQ-2: «запросы всего» — requests-счётчика в /metrics
    нет; рекомендация — не рисовать строку (см. Open questions)]"""

class Deltas:
    """Дельты счётчиков ЗА ТИК — «пульс завершений», НЕ скорость
    (счётчики обновляются только на done: в работе Δ=0, на завершении
    скачок). Перенос hfctl Deltas 1:1 (hfctl watch_tui.py:258–298),
    gufo-ключи. Отрицательный Δ (recreate/reset счётчиков) → None на тике,
    база всё равно обновляется; reset() — после тика с мёртвым сервером,
    чтобы после поднятия не было ложных дельт."""
    def update(self, m):  # m: dict|None (None → полный reset-эффект)
        """@returns dict  # {'prefill': int|None,    # Δprompt_tokens_total, ток/тик
                             'decode':  int|None,    # Δtokens_predicted_total
                             'drafts':  int|None,    # Δspec_decode_num_drafts_total
                             'gen_last': float|None} # Δpredicted_total/Δpredicted_seconds
                                                     # [tok/s] — «последний запрос»;
                                                     # Δseconds==0 при Δtotal>0 → None
                                                     # (деление защищено)"""

SPARK_UTF = '▁▂▃▄▅▆▇█'; SPARK_ASCII = ' .:-=+*#'
def sparkline(values, width):
    """1:1 hfctl sparkline (watch_tui.py:394): последние width значений,
    нормировка по max; пусто → ''"""

def log_ts_utc_epoch(line):
    """@returns int|None  # epoch UTC: первый re-матч
    r'(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})' → calendar.timegm
    (метки движка — UTC, контейнер не трогаем); нет метки → None"""

def log_line_local(line):
    """@returns string  # TZ-конверсия для рендера: метка найдена →
    'HH:MM:SS ' + хвост строки после метки (time.localtime(epoch));
    метки нет → строка как есть (НЕ выдумываем время).
    Хранить в буфере СЫРЫЕ строки, конверсия — на рендере (детерминизм
    паузы/перерисовки)."""

def parse_route_lines(lines):
    """@returns dict  # {'spec','sessions','ctx','model'} из ПОСЛЕДНЕЙ строки
    event=load_completed; семантика parse_route lib/health.sh:32 1:1
    (model = подстрока между 'model=' и ' sessions=' — имена с пробелами
    целиком); строки нет → все '' """

def parse_configured_lines(lines):
    """@returns dict  # {'sessions','ram_cache','capacity','automatic','disk'}
    из ПОСЛЕДНЕЙ event=configured; семантика parse_configured
    lib/commands.sh:915 1:1 (в GiB переводит рендер); строки нет → все ''"""
```

#### watch_tui.py (v2) — сборка

- **collect()**: `{'engine_ok', 'metrics', 'stats': engine_stats(m), 'gpu',
  'cpu_t', 'mem', 'ready': bool}`; /metrics (curl, таймаут 5 с) — как v1;
  НОВОЕ: `/ready` (curl rc 0 → режим «готов», иначе «нет»); gpu/cpu_t/mem —
  каждый тик независимо от сервера (хост-данные). Провал /metrics →
  `engine_ok=False` + `deltas.reset()`. 2 curl-вызова на тик.
- **LogStreamer**: v1 1:1 (сид `--tail 50` синхронно до первой рамки, live
  `--tail 1 -f` в daemon-потоке, deque(500), дедуп хвоста сида, stderr→STDOUT
  — podman печатает логи в stderr), НО БЕЗ `-t` в обоих вызовах (DoD №4).
- **Deltas + history**: три deque ширины ~W/2−18 (свежие не отбрасываются,
  hfctl-правило) — decode/prefill/drafts.
- **Блоки (порядок фикс.):** строка 0 — status bar v1 (модель из
  parse_route_lines + интервал + пауза + q); «Железо» (левая колонка) |
  «Память» (правая); «Движок» (вся ширина); «Скорость» (вся ширина); «Логи»
  (остаток, минимум 3). Деградация узкого/низкого экрана — правило v1:
  хвостовые строки блоков отбрасываются, логи держат LOG_MIN=3.
- **rows_Железо**: GPU temp (цвет temp_color), CPU Tctl (цвет), GPU freq
  (MHz), GPU power (W), GPU load (busy %), VRAM/GTT (GiB, перевод из Б).
  read_gpu None → все GPU-значения '?' + строка «карта AMD (0x1002) не
  найдена»; датчик по отдельности отсутствует → '?' (per-field None).
- **rows_Память**: RAM `<avail>/<total> GiB` + bar (hfctl 1:1, ширина ≤10);
  цвет по заполнению: доля avail/total ≤0.1 → красный, ≤0.2 → жёлтый
  (пороги зеркалят температуры 90/80; ТЗ «цвет по заполнению» чисел не даёт —
  решение зафиксировано здесь); VRAM used, GTT used (GiB, без цвета —
  ёмкости в ТЗ нет; vram_total — в out-of-scope proposals).
- **rows_Движок** (dead → ровно `[('недоступен','')]`, v1):
  Роут: `dflash2 · s1 · ctx 262144` (parse_route_lines; пусто → '?');
  Режим+cache: `готов | cache: ram on · disk 64 GiB` (/ready + configured);
  Генерация: `20.1 tok/s (средн) · 76.9 (последний)`;
  Prefill: `147.0 tok/s (средн)`;
  Кэш-эффект: `99.7 %`;
  **Спекуляция принято: `98.5 %` — выделенная строка (bold),** DoD №3;
  Draft-пульс: sparkline(Δdrafts) + число `+7 ток/тик`;
  KV: `12.3 % · пик 27155`;
  Очередь: `0/0`; Всего: `prompt 12.3k · predict 5.1M · cached 99.1k`
  (fmt_tok v1).
  Спарклайны подпись «пульс завершений» — блок «Скорость»: строки
  decode/prefill/drafts sparkline (DoD №5: НЕ скорость; unit токенов за тик —
  колонка «ток/с» таблицы ТЗ для draft-строки противоречит её же абзацу
  «Свойства счётчиков», абзац старше — фиксируем ток/тик).
- **rows_Логи**: хвост буфера; каждая строка через log_line_local.
- **Цвета**: C_RED=1, C_GREEN=2, C_YELLOW=3; `temp_color(deg, fmt)` — перенос
  hfctl 1:1: по НАПЕЧАТАННОМУ значению (79.95 печатается «80.0» → жёлтый);
  ≥90 красный, 80–89.9 жёлтый (DoD №1). Красный engine_ok=False — v1 точка
  статуса.
- **plain-режим** (не-TTY): строки БЕЗУСЛОВНО раз в interval, первая сразу;
  префиксы фикс. для батареи:
  `[железо] GPU 54.0°C 600MHz 5W 3% VRAM 3.2 GiB GTT 1.1 GiB | CPU 45.0°C`
  `[память] RAM 45.2/60.4 GiB | VRAM 3.2 GiB | GTT 1.1 GiB`
  `[движок] gen 20.1/76.9 tok/s | prefill 147.0 | кэш 99.7% | спек 98.5% |
  KV 12.3% пик 27155 | оч 0/0 | dflash2·s1·ctx262144 | готов`
  `[скорость] пульс: decode +12 prefill +93 drafts +7 (ток/тик)`
  `[логи] <TZ-конвертированная строка>`
  Мёртвый сервер: РОВНО одна строка «недоступен» на тик (dead_line v1 1:1),
  без спама, без traceback.
- **Клавиши TUI**: q/Q — выход rc 0; +/= и -/_ — интервал ±1 с (min 1);
  p — пауза live-лога. v1 1:1 (brief: TTY → TUI q/+/-/p).
- **Входы env** — v1 1:1: GFCTL_WATCH_PORT (def 8080, D2), INTERVAL (def 2;
  <0.05 — батарея без сна), CONTAINER (def gufo); швы GFCTL_WATCH_TICKS
  (0/нет = ∞) и GFCTL_WATCH_SELFCHECK=1 — сохранить.
- **selfcheck()** — расширяется (см. Test strategy); формат итога
  `selfcheck: N/N ok` сохраняется.

### Потоки данных

```
/sys/class/drm/card* ─┐
/sys/class/hwmon ─────┤ watch_sysfs ──┐
/proc/meminfo ────────┘              │
                                     ├─→ collect() snapshot ─→ TUI (curses, TTY)
curl /metrics ─→ parse_metrics ──→ engine_stats + Deltas ─┘   или plain (стрим)
curl /ready ────────────────────────────┘
podman logs (БЕЗ -t) ─→ LogStreamer.deque ─→ parse_route_lines / parse_configured_lines
                                        └─→ log_line_local ─→ блок «Логи»
```

### Края (ожидаемое поведение)

| Край | Поведение |
|---|---|
| Карта AMD не найдена (нет card* / vendor≠0x1002) | read_gpu → None; GPU-строки '?', строка «карта AMD (0x1002) не найдена» |
| Датчик есть, поле нет (sclk/power/busy/VRAM/GTT) | '?' в своём поле (per-field None, hfctl 1:1) |
| k10temp нет | CPU Tctl '?' |
| Сервер мёртв | plain: ровно одна «недоступен» на тик (v1); TUI: «Движок»=[('недоступен','')]; Железо/Память продолжают рисоваться (хост жив); deltas.reset() — без ложных дельт после поднятия; rc 0 |
| /metrics пуст (0 счётчиков) / ключа нет | engine_stats → None/None-поля → '?'/'—'; sparkline '' |
| До первого done (счётчики 0) | gen_avg/prefill: деление на 0 → '—'; gen_last: базы нет → '—'; sparkline пустая; средние НЕ мигают в idle (счётчики кумулятивны) |
| Recreate между тиками (счётчики сброшены) | отрицательный Δ → None на тике, база обновлена; роут обновляется сам (последняя load_completed в буфере) |
| Запрос в работе | средние его не учитывают (консервативно, как hfctl) — это документированное свойство, не баг |
| Не-TTY | plain-стрим (v1-семантика: строки безусловно каждый интервал) |
| TTY-клавиши | q/Q выход rc 0; +/- интервал; p пауза лога (v1) |
| Строка лога без распознанной метки | печатается как есть, время не выдумывается |
| podman нет/контейнера нет | сид и стрим молча пусты, «(ждём логи…)» (v1) |
| initscr краш (TERM кривой) | фолбэк в plain (v1) |
| Нужна вертикаль | деградация v1: хвосты строк блоков, логи ≥3 строк |

## Test strategy

**Инструменты:** существующие швы батареи — faux-bin curl (`GFCTL_FAUX_METRICS`
— файл-оверрайд текста /metrics; счётчик вызовов `GFCTL_FAUX_CNT.curl`;
`GFCTL_FAUX_PODMAN_LOGS` — текст лога), env-швы watch (`GFCTL_WATCH_TICKS`,
`GFCTL_WATCH_SELFCHECK`, `INTERVAL<0.05`). НОВЫЙ шов faux curl:
`GFCTL_FAUX_METRICS_SEQ="файл1:файл2:…"` — вызов №N отдаёт файл min(N, длина
списка) (счётчик .curl уже ведётся; без переменной — старое поведение
`GFCTL_FAUX_METRICS`, соседние тесты не меняются).
**Фикстуры:** `tests/fixtures/metrics_snap1.txt` (стабильный снапшот: крупная
база, средние сходятся с движковыми gauge-значениями), `metrics_snap2.txt`
(live-дельта: predicted_total +300 / predicted_seconds_total +4.0,
prompt_total +512 / prompt_seconds_total +3.2, drafts +60 / accepted +58,
kv 0→0.12, processing 0→1); лог-фикстура `$TMP/logtz` с полными метками
`YYYY-MM-DD HH:MM:SS [INFO] … load_completed …` (TZ-ассерты).

| DoD | Внутренняя проверка | Внешнее (живой прогон, этап 5) |
|---|---|---|
| 1 Железо (sysfs) | selfcheck: read_gpu на фейковом дереве (tempfile: card0 vendor 0x1002, два hwmon с temp1_input 35875/41000 → temp_c=41.0 MAX, freq1_input/power1_input/мем-файлы, busy из device/); карта без 0x1002 → None; per-field None; read_cpu_temp k10temp; temp_color границы 79.9/80/89.9/90 + «как печатается» (79.95→жёлтый); plain-строка `[железо]` | сверка temp/sclk/power/busy с `sensors`/hwmon живой машины |
| 2 Память | selfcheck: read_mem (v1 уже зелёный — не регрессирует); цвет-пороги avail/total 0.1/0.2; plain-строка `[память]` | RAM/VRAM vs free/машинные значения |
| 3 Движок (формулы) | selfcheck: engine_stats на EXP-007-снапшоте (18/0.8935→20.1; 93/0.6327→147.0; кэш 27044/(27044+93); спек 11/7→157.1%; KV, пик 27155, очередь); деление на 0 → None; Deltas-последовательность (база→Δ→отрицат.Δ→reset); gen_last=Δ/Δ; battery: snap1→snap2 (2 тика, GFCTL_FAUX_METRICS_SEQ): decode +300, gen_last=75.0 tok/s, drafts +60, средние ~стабильны | счётчики движутся при живом запросе, отображение 200 |
| 3 роут/режим/configured | selfcheck: parse_route_lines (модель с пробелами, последняя строка побеждает, поля spec/sessions/ctx); parse_configured_lines (ram_cache/disk); battery: LOGSP-фикстура → `dflash2|mtp · sN · ctxN` в строке [движок] | роут совпадает с `gfctl status` |
| 4 Логи без -t + TZ | battery: faux-лог podman — `grep -c '^podman logs -t'` = 0 (БЕЗ -t!), seed `--tail 50` присутствует; [логи]-строка содержит конвертированное HH:MM:SS; selfcheck: log_ts_utc_epoch/log_line_local при TZ=UTC (time.tzset) — точное время; строка без метки — как есть | время в [логи] совпадает с `date` хоста (TZ-конверсия верна) |
| 5 Свойства счётчиков | battery snap1→snap2 (см. DoD 3): idle-тик между done — дельты 0, средние неизменны (snap2 с нулевыми Δ → третий тик без изменений); подпись «пульс завершений» в [скорость] | наблюдение пульса на живом done |
| 6 Батарея целая | `bash tests/run_checks.sh` — rc 0, все до-этапные ассерты зелёные (счётчик растёт только на новые); базлайн HEAD в dev-report; `bash -n gfctl lib/*.sh`; `python3 -m py_compile tpl/python/*.py` (3 файла) | — |
| 7 SPEC той же дельтой | SPEC §3 строка `watch` — v2-текст (блоки/клавиши/TZ); §8 ячейка watch; `spec_validate` прогнан, дифф SPEC в коммите подэтапа | — |
| 8 BLOCKED-EXTERNAL | — | EXP-скрипт окна этапа 5: живой прогон + температуры + TZ (сверка с `date`), RESULT-строка |

TUI-геометрия (узкие экраны) батареей не покрывается — headless-проверка
ограничена rows_*/selfcheck; живой контроль в окне этапа 5.

## Risks and rollback

| Риск | Митигация |
|---|---|
| OQ-1/OQ-2 (имена метрик ТЗ, которых нет в факт-базе) | код этих строк НЕ пишется до ответа пользователя; всё остальное — не зависит (engine_stats изолирован) |
| Регрессия 363-ассертной батареи | watch-ассерты §37 переписываются только под v2-формат (те же grep-паттерны префиксов); соседние секции не трогаются; базлайн фиксируется до правок |
| Неверный порог «цвет по заполнению» RAM | решение зафиксировано в Design (0.1/0.2 зеркально температурам); правка — одна константа |
| TZ-метки движка не UTC (разочарование в окне 5) | graceful: строка как есть при отсутствии метки; конверсия изолирована в log_line_local; сверка с `date` в EXP |
| TUI не влезает на 80×24 | правило деградации v1 (хвосты блоков, логи ≥3); живой осмотр в окне 5 |
| Производительность (2 curl + sysfs на тик) | при interval≥1 с — пренебрежимо; /metrics ~14 ключей |

**Rollback:** дельта = 2 новых файла + rewrite watch_tui.py + секция §37 батареи
+ строка SPEC. Shell/юниты/данные не затронуты → `git revert` коммита подэтапа
возвращает v1 без каскада (watch_tui.py v1 в git-истории; LIVE-рисков нет —
живой прогон в этом подэтапе не выполняется по D6).

## References

- SPEC.md §3 (строка `watch` — заменяется), §6 (роут из load_completed, /ready),
  §8 (ячейка watch — той же дельтой).
- ТЗ: `.dev/tasks/4/4.5-watch-v2-decision.md` — блоки/формулы/приёмка.
- Принцип python/shell: `.dev/tasks/4/4.4-layout-python-decision.md`.
- DECISIONS: D2 (порт 8080), D6 (живые запуски — только по GO, окно этапа 5).
- FACTS: F14 (машины, hwmon/k10temp); F20 (BF16=30 — к watch не относится).
- Факт-база /metrics: `.dev/external/EXP-007-agentcheck.result.txt:109–123`
  (14 ключей — полный список; верификация имён ТЗ — Open questions).
- Формат строк лога движка: EXP-005/006 result (`2026-11-17 23:28:03 [INFO]
  [gpu] event=…` — время в строках, без podman `-t`).
- Эталон переноса 1:1: `/workspace/hfctl/tpl/python/watch_tui.py`
  (GPU_SPEC/read_gpu:172–214, read_cpu_temp:217–225, Deltas:258–298,
  sparkline:394, temp_color:431–444, rows_hardware/rows_memory).
- Текущий код: `lib/commands.sh:1060–1093` (cmd_watch — не меняется),
  `lib/health.sh:32` (parse_route — семантика), `lib/commands.sh:915`
  (parse_configured — семантика), `tpl/python/watch_tui.py` (v1),
  `tests/run_checks.sh` (faux-bin:32–90, секция §37:1415–1453).

## Open questions

Нет — OQ-1/OQ-2 закрыты кодом движка/решением пользователя 2026-11-21
(см. Round 2 ниже: формулы, полный список ключей 12+5, блок «Всего»).

## Round 2 (2026-11-21): ревизия формул по коду движка

Основание — вердикт пользователя, верифицированный оркестратором по коду
движка (авторитетный источник): `/workspace/gufo/src/cli/serve/http_server.cpp:1595–1685`
(эмиттер /metrics), `docs/internal/server.md:1557–1583` (семантика обновления).
Round 1 не переписывается; ниже — точечные замены фрагментов Round 1 (список
замен — для developer/reviewer, чтобы никто не гадал, что старше).

### Что заменяется в Round 1 (карта замен)

| Фрагмент Round 1 | Статус |
|---|---|
| `engine_stats`: docstring-формулы `cache_pct`, `spec_pct`, ключи `gen_last`, строка prefill | ЗАМЕНЕНЫ (таблица v2 ниже) |
| `Deltas.update` ключ `'drafts'` (источник `Δspec_decode_num_drafts_total`) | ЗАМЕНЁН: `Δspec_decode_num_draft_tokens_total` (токены, не раунды) |
| `Deltas.update` ключ `'gen_last'` (Δ/Δ) | УДАЛЁН: «последний» = движковые speed-gauge (см. v2-таблицу) |
| «Движок» строка «Всего: prompt … · predict … · cached …» | ЗАМЕНЕНА блоком «Всего» (3 строки, OQ-2) |
| «Железо» rows | ДОПОЛНЕНЫ строкой Device lost |
| «Движок» rows | ДОПОЛНЕНЫ строкой Prompt-lookup (скрытие при нулях) |
| plain-строки `[движок]`/`[железо]`/`[скорость]` | скорректированы под v2 (ниже) |
| Фикстуры snap1/snap2 (2 файла) | ЗАМЕНЕНЫ на snap1/snap2/snap3 (3 файла) |
| Test strategy (DoD 3/5 + selfcheck) | дополнен ассертами v2 (ниже) |
| Кросс-чек «gauge == формула» | Смягчён: gauge = ПОСЛЕДНЯЯ ненулевая скорость (docs:1561) — равенство формуле гарантировано только на одно-запросном снапшоте (EXP-007); selfcheck сверяет формулу на снапшоте, gauge печатается отдельно |

### Полный список ключей /metrics (код, 12 счётчиков + 5 gauge)

Счётчики: `gufo_device_lost_total`; `llamacpp:prompt_tokens_total`
(HELP: «excluding cache hits» — кэш-хиты НЕ входят); `llamacpp:prompt_tokens_cached_total`;
`llamacpp:prompt_seconds_total`; `llamacpp:tokens_predicted_total`;
`llamacpp:tokens_predicted_seconds_total`; `llamacpp:n_tokens_max` (TYPE counter
— монотонный максимум); `llamacpp:spec_decode_num_drafts_total` (**РАУНДЫ**
верификации, HELP «verification rounds»); `llamacpp:spec_decode_num_draft_tokens_total`;
`llamacpp:spec_decode_num_accepted_tokens_total`; `gufo_spec_lookup_tokens_total`;
`gufo_spec_lookup_accepted_tokens_total`.
Gauge: `llamacpp:prompt_tokens_seconds` (LastPromptSpeed), `llamacpp:predicted_tokens_seconds`
(LastGenSpeed), `llamacpp:requests_processing`, `llamacpp:requests_deferred`,
`llamacpp:kv_cache_usage_ratio`.
Факт-база EXP-007 (14 ключей `llamacpp:*`) — подмножество: gufo_*-счётчики в её
снимок не попали; парсер обязан терпеть отсутствие ЛЮБОГО ключа (старый образ →
Device lost '?', lookup-строка скрыта — отсутствие = нулевые суммы).
**НЕ ИСПОЛЬЗОВАТЬ (hard rule):** `gufo_prompt_state_budget_bytes` /
`gufo_prompt_state_reserved_bytes` / `gufo_prompt_state_available_bytes` —
эмитятся только claim-раннерам (docs:1580–1583), на Qwen/Flash-Next их нет;
parse_metrics их пропускает как прочие, engine_stats/рендер не читают никогда.

### Семантика обновления (свойства счётчиков v2 — заменяет абзац Round 1 «Свойства»)

- LIVE (по чанкам, «rates show live throughput» — docs:1557–1558):
  `prompt_tokens_total`, `prompt_tokens_cached_total`, `tokens_predicted_total`;
- ТОЛЬКО на done/cancel (docs:1562–1572, включая отклонённые/нечитанные запросы;
  упавшие в планировщике — не добавляют ничего): `prompt_seconds_total`,
  `tokens_predicted_seconds_total`, `spec_decode_num_drafts_total` (раунды),
  `spec_decode_num_draft_tokens_total`, `spec_decode_num_accepted_tokens_total`,
  `gufo_spec_lookup_*`, подъём `n_tokens_max`;
- speed-gauge — «последняя ненулевая скорость» запроса (docs:1561): в idle
  стабильны, нулевая скорость старое значение не затирает;
- следствия: Δtoken-счётчиков за тик = живой пульс (движется ВО ВРЕМЯ генерации,
  не только на done); Δdraft_tokens/Δseconds за тик = пульс завершений;
  средние по секундным знаменателям консервативны и стабильны между done;
  Δ — не скорость (подпись «пульс» сохраняется).

### Таблица формул v2 (engine_stats)

| Показатель | Формула v2 | Примечание |
|---|---|---|
| Генерация (средн.) | `tokens_predicted_total / tokens_predicted_seconds_total` | без изменений |
| Генерация (последний) | gauge `predicted_tokens_seconds` | ЗАМЕНА Δ/Δ; «последняя ненулевая» |
| Prefill (средн.) | `prompt_tokens_total / prompt_seconds_total` | **OQ-1 ЗАКРЫТ** (ровно эту семантику несёт движок; имя из ТЗ `prompt_tokens_seconds_total` не существует) |
| Prefill (последний) | gauge `prompt_tokens_seconds` | НОВОЕ, рядом с «генерация последнего» |
| Кэш-эффект % | `prompt_tokens_cached_total / (prompt_tokens_total + prompt_tokens_cached_total) × 100` | **ПОПРАВКА**: prompt_tokens_total уже исключает кэш-хиты → старый знаменатель давал >100 %; новый ≤100 по построению |
| Спекуляция принято % | `spec_decode_num_accepted_tokens_total / spec_decode_num_draft_tokens_total × 100` | **ПОПРАВКА**: знаменатель — ПРЕДЛОЖЕННЫЕ ТОКЕНЫ; `num_drafts_total` — раунды (11/7=157 % на EXP-007 — ерунда; 11/30=36.7 % — честно) |
| Draft-пульс (sparkline) | `Δspec_decode_num_draft_tokens_total` | **ПОПРАВКА**: токены, не раунды; единица — токенов за тик |
| KV заполнение / пик | `kv_cache_usage_ratio × 100` / `n_tokens_max` | без изменений (usage — мгновенный gauge «in-flight over sessions×context», retained-кэш не считается) |
| Очередь | `requests_processing / requests_deferred` | gauge: admitted (вкл. cache-prep) / ждут сессию |
| Prompt-lookup % (НОВОЕ) | `gufo_spec_lookup_accepted_tokens_total / gufo_spec_lookup_tokens_total × 100` | строка скрыта при нулевых СУММАРНЫХ (и при отсутствии ключей); иначе `<accepted>/<tokens> (<pct>%)` |
| Device lost (НОВОЕ, блок «Железо») | `gufo_device_lost_total` | значение 0 — обычно; **>0 — красным** (потеря GPU-контекста); отсутствует → '?' |

### Правки блоков и plain-форматов

- rows_«Движок» вместо строки «Всего» (**OQ-2 ЗАКРЫТ** — состав пользователя):
  `Префил: <prompt_tokens_total> обработано · <cached_total> из кэша` (одна
  строка — оба про prefill); `Сгенерировано: <tokens_predicted_total>`;
  `Очередь: <q_proc>/<q_def>` (остаётся отдельной строкой).
- rows_«Движок» + строка `Prompt-lookup: …` (см. v2-таблицу, скрытие при нулях).
- rows_«Железо» + строка `Device lost: <N>` (attr C_RED при N>0).
- Спарклайны «Скорость»: decode/prefill — live-пульс (Δtoken-счётчиков),
  drafts — пульс завершений (Δdraft_tokens); подпись блока «пульс завершений»
  сохраняется, для decode/prefill подпись «live-пульс».
- plain `[движок]`: `gen <avg>/<gauge_last> tok/s | prefill <avg>/<gauge_last> |
  кэш <pct>% | спек <pct>% | KV <pct>% пик <N> | оч p/d | префил <tok>+<cached>кэш |
  сген <tok> | роут… | режим…`; сегмент lookup добавляется только когда видим.
- plain `[железо]` хвост: `… | lost <N>`; `[скорость] пульс: decode +N prefill +N
  drafts +N (ток/тик)` — N из Δdraft_tokens.

### Фикстуры батареи v2 (заменяют snap1/snap2 → три файла)

`GFCTL_FAUX_METRICS_SEQ="f1:f2:f3"` (вызов №N → файл min(N,3); без переменной —
старое поведение). Содержимое — все 17 ключей кода (полный список выше);
developer фиксирует точный текст, дельты обязательны:

- **snap1** (стабильная база): prompt=10000, cached=990000 (кэш-эффект ровно
  99.0 %), prompt_s=100 (prefill_avg 100.0), predicted=50000, predicted_s=2500
  (gen_avg ровно 20.0), drafts=5000 РАУНДОВ, draft_tokens=100000, accepted=60000
  (acceptance ровно 60.0 % — по draft_tokens), n_tokens_max=262144, kv=0.12,
  processing=0, deferred=0, gauge prompt_tokens_seconds=98.7 /
  predicted_tokens_seconds=21.4, device_lost=0, lookup 0/0;
- **snap2** (live-тик БЕЗ done): predicted +300 (=50300), prompt +512 (=10512),
  cached +512 (=990512); секунды, раунды, draft_tokens, accepted, n_tokens_max —
  БЕЗ изменений → decode-пульс +300, prefill-пульс +512, drafts-пульс 0,
  gen_avg НЕИЗМЕННА (20.0), acceptance не пересчитывается по-новому (числитель/
  знаменатель заморожены), кэш-эффект 98.95 % (≤100);
- **snap3** (done-тик): prompt_s +5.2 (=105.2), predicted_s +15 (=2515), drafts
  +60 (=5060), draft_tokens +1000 (=101000), accepted +640 (=60640 → 60.04 %),
  n_tokens_max → 27155 (подъём), kv → 0.34, gauge predicted_tokens_seconds → 53.3;
  token-счётчики стоят (живых чанков нет) → decode/prefill-пульс 0, drafts-пульс
  +1000.

### Test strategy — дополнения (к таблице Round 1)

| Проверка | Ассерт |
|---|---|
| Кэш-эффект ≤100 (новый знаменатель) | selfcheck: snap1 → ровно 99.0 %; EXP-007-кейс 27044/(27044+93)=99.66 %; инвариант pct ≤ 100 на всех фикстурах |
| Acceptance по токенам | selfcheck: snap1 → ровно 60.0 % (accepted/draft_tokens); EXP-007-кейс 11/30=36.7 %; раунды (drafts) в формулах НЕ фигурируют (grep по fixture-числам 5000 не даёт 60000/5000) |
| Live-пульс token-счётчиков без done | battery tick2 (snap1→snap2): [скорость] decode +300 prefill +512 drafts 0; [движок] gen_avg 20.0 не изменилась; кэш-эффект 98.95 % |
| Пульс завершений | battery tick3 (→snap3): drafts +1000 (токены), acceptance 60.04 %, пик 27155, gen_last 53.3 (gauge) |
| Device lost | selfcheck: rows attr C_RED при >0, обычный при 0; '?' при отсутствии ключа |
| Prompt-lookup скрытие | selfcheck: строки нет при 0/0 и при отсутствии ключей; видна при >0 (snap3-вариант с lookup 200/250 → 80 %) |
| prompt_state_* не читаются | selfcheck: fixture с gufo_prompt_state_budget_bytes=… → в выводе watch сегментов нет (парсер проходит, рендер молчит) |
| Deltas v2 | selfcheck: 'drafts' = Δdraft_tokens (не раундов); 'gen_last' ключа больше нет; decode/prefill на token-дельтах; отрицат.Δ/reset — как Round 1 |

DoD формулировки не меняются (формулы — носитель DoD остаётся brief; настоящая
ревизия — уточнение их арифметики по коду движка в рамках того же DoD №3/№5).

### References (Round 2)

- `/workspace/gufo/src/cli/serve/http_server.cpp:1595–1685` — эмиттер /metrics
  (полный список 12+5, HELP-тексты, условные prompt_state-gauge);
- `gufo/docs/internal/server.md:1557–1583` — семантика обновления
  (live-token-счётчики; done-набор; «latest nonzero» gauge; prompt_state
  только у claim-раннеров).

## Round 3 (2026-11-21): приёмка отклонений developer

Отклонения из dev-report рассмотрены по коду; тела Round 1/2 не
переписываются — ниже вердикты с силой дизайна.

1. **Фикстура Round 2 «gen_avg НЕИЗМЕННА (20.0)» — отклонение ПРИНЯТО,
   пункт Round 2 уточнён.** Арифметически невыполнимо: token-счётчики
   LIVE по чанкам (docs:1557–1558), числитель вырос → 50300/2500 = 20.12.
   Правильная семантика: в live-тике без done секундный знаменатель
   заморожен (done-only, docs:1562–1565), средняя ползёт ВВЕРХ по формуле —
   это и есть свойство «консервативна» (Round 2 «Семантика обновления»).
   Ассерт: точное значение по формуле (20.12 → печатается «20.1», допуск —
   округление fmt1) + инвариант «средняя не падает в live-тике». Developer
   реализовал ровно это; тест-стратегия валидна как есть.
2. **uptime v1 → v2 не входит — ПРИНЯТО.** В составе v2 (Round 1 «Движок»,
   Round 2) строки uptime нет, модель — в status bar; удаление корректно.
   Желание вернуть (в «Режим») — out-of-scope proposals dev-report, в
   этом подэтапе не делается.
3. **Заголовок TUI-блока в верхней границе рамки — ПРИНЯТО** (cosmetic;
   экономия 4 строк на 80×24 против v1-каркаса; правило деградации
   Round 1 не нарушено, ассерты батареи текст-независимы — пинуются
   plain-строки и rows_*, не рамки).

