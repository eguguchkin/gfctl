# Dev report: 4.5-watch-v2 (watch v2 по ТЗ 4.5 + Round 2)

- Дата: 2026-11-21 · fix round: 1 (первичная реализация)
- Дизайн: task.md (Round 1 + Round 2 — формулы v2, карта замен соблюдена)

## Что было сделано (по пунктам скоупа)

1. **«Железо»** (DoD 1) — `tpl/python/watch_sysfs.py` (НОВЫЙ): `read_gpu`
   (первая карта vendor 0x1002; temp_c = MAX по temp1_input ЭТОЙ карты —
   ловушка v1 `read_first_temp` устранена; sclk/power/busy/VRAM/GTT,
   масштабы hfctl 1:1), `read_cpu_temp` (k10temp Tctl), `read_mem`.
   Пороги цветов в `watch_tui.py`: `temp_color` (жёлтый 80–89.9, красный
   ≥90 — по НАПЕЧАТАННОМУ значению, hfctl 1:1), device-lost красным при >0
   (Round 2).
2. **«Память»** (DoD 2) — `rows_memory`: RAM avail/total + bar (ширина 10),
   цвет по заполнению (≤0.1 красный, ≤0.2 жёлтый — пороги зафиксированы в
   task.md), VRAM/GTT used.
3. **«Движок»** (DoD 3) — `tpl/python/watch_engine.py` (НОВЫЙ):
   `engine_stats` формулы v2 (генерация/prefill средние по кумулятивным +
   speed-gauge «последний»; кэш-эффект = cached/(prompt+cached) ≤100;
   acceptance = accepted/draft_tokens (не раунды); KV %/пик; очередь;
   префил/сгенерировано; lookup % при ненулевых; device_lost).
   `parse_route_lines`/`parse_configured_lines` — семантика
   `parse_route` (health.sh) / `parse_configured` (commands.sh) 1:1;
   роут — в строке «Роут», режим — `/ready` + configured. Спекуляция —
   выделенная строка (A_BOLD). gufo_prompt_state_* — не читаются (hard rule).
4. **«Логи»** (DoD 4) — LogStreamer БЕЗ `-t` (сид `--tail 50`, live
   `--tail 1 -f`); TZ-конверсия UTC→локальный НА РЕНДЕРЕ
   (`log_ts_utc_epoch`/`log_line_local`, буфер хранит сырые строки);
   TUI + plain — оба режима.
5. **Свойства счётчиков** (DoD 5) — `Deltas`: decode/prefill — LIVE
   token-счётчики, drafts — Δdraft_tokens; отрицательный Δ → None + reset
   на сбое чтения (без ложных дельт после recreate); «Скорость» —
   sparkline (hfctl autoscale 1:1), подпись «пульс завершений».
6. **Харнес** — `tpl/python/watch_tui.py` (rewrite v1→v2): collect
   (/metrics + /ready, 2 curl на тик), клавиши q/+/-/p, не-TTY стрим
   (5 строк/тик: железо/память/движок/скорость/логи), мёртвый сервер —
   ровно одна строка «недоступен» на тик без traceback, швы батареи
   GFCTL_WATCH_TICKS/SELFCHECK/INTERVAL<0.05 сохранены, selfcheck
   расширен 24→80 ассертов.
7. **Батарея** (DoD 6) — `tests/run_checks.sh`: шов faux curl
   `GFCTL_FAUX_METRICS_SEQ="f1:f2:f3"` (вызов №N → файл min(N,длина));
   §37 переписана (25 ассертов): 3 снапшота SEQ, live-пульс без done,
   done-пульс, заморозка/крип средних, кэш ≤100 и точные 99.0/60.0,
   podman logs без -t, TZ-конверсия в [логи], скрытие lookup,
   prompt_state не читаются, selfcheck-пин 80/80. Фикстуры
   `tests/fixtures/metrics_snap{1,2,3}.txt` (полные 17 ключей эмиттера,
   числа из task.md Round 2).
8. **SPEC** (DoD 7) — `.dev/SPEC.md`: §3 строка `watch` переписана (v2:
   блоки, формулы, TZ, без -t); §8 ячейка watch (`draft-приём` из логов →
   вычисляемые метрики). `spec_validate` — валидно.
9. **Shell-слой** — НЕ менялся (git diff lib/ gfctl пуст); cmd_watch
   отдаёт те же env.

**Файлы:** `tpl/python/watch_sysfs.py` (new), `tpl/python/watch_engine.py`
(new), `tpl/python/watch_tui.py` (rewrite), `tests/run_checks.sh` (SEQ + §37),
`tests/fixtures/metrics_snap1..3.txt` (new), `.dev/SPEC.md` (§3, §8).

## Как проверял внутренне (команды + результаты)

| Проверка | Команда | Результат |
|---|---|---|
| lint shell | `bash -n gfctl lib/*.sh` | OK |
| lint battery | `bash -n tests/run_checks.sh` | OK |
| py | `python3 -m py_compile tpl/python/*.py` | OK (6 файлов) |
| selfcheck | `GFCTL_WATCH_SELFCHECK=1 python3 tpl/python/watch_tui.py` | `selfcheck: 80/80 ok`, rc 0 |
| usage-гейт (AGENTS) | `./gfctl` без аргументов | usage, rc 1 |
| батарея | `bash tests/run_checks.sh` | **rc 0, PASS=381 FAIL=0** |
| базлайн батареи | прогон до правок | rc 0, PASS=367 FAIL=0 |
| spec | `spec_validate` | валидно |
| shell-слой не тронут | `git diff lib/ gfctl` | пусто |

Арифметика батареи: 367 (базлайн) − 11 (старые watch-ассерты §37) +
25 (новые) = 381 ✓. Самопроверка формул: EXP-007-снапшот в selfcheck
(gen_avg 18/0.8935 = 20.14; prefill 93/0.6327 = 146.98; кэш 99.66 ≤100;
acceptance 11/30 = 36.67 по токенам — раунды 11/7 = 157 % не используются);
точные значения фикстур: кэш ровно 99.0, gen_avg 20.0→20.12→20.0,
acceptance 60.0→60.04.

## Не проверено внутренне (BLOCKED-EXTERNAL, окно этапа 5 по D6 + GO)

- живой прогон: модель грузится → счётчики движутся → отображение 200;
- температуры: сверка GPU/CPU с `sensors`/hwmon живой машины;
- TUI-геометрия на реальном TTY (80×24: деградация режет хвост «Движка»;
  раскладка блоков headless не проверяется — только rows_*/selfcheck);
- TZ-конверсия: сверка времени в [логи] с `date` хоста (в батарее —
  форматная проверка, TZ-зависимость детерминирована только в selfcheck
  через TZ=UTC);
- gufo_*-ключи на живом образе (device_lost/lookup — семантика снята с
  кода эмиттера, живой ответ не видел).

## Известные ограничения / допущения (для tester/reviewer)

- **Отклонение от текста task.md Round 2 (фикстуры):** там «gen_avg
  НЕИЗМЕННА (20.0)» в live-тике — арифметически невыполнимо при
  live-числителе (50300/2500 = 20.12). Реализовано семантически верное
  свойство из того же Round 2 («средние консервативны, не падают»):
  ассерт = точная формула 20.12 → печатается «20.1». Тест-стратегию не
  ломает, но пункт фикстур task.md стоит поправить архитектору/принять
  как есть.
- uptime v1 убран (в составе v2 Round 2 строки нет); модель — в status bar.
- TUI: заголовок блока перенесён в верхнюю границу рамки (экономия 4
  строк на 24-линейном терминале против v1-каркаса; в рамках правила
  деградации task.md).
- plain не запускает live-лог-поток (только сид) — v1 семантика.
- История пульса — deque maxlen 120 тиков, рендер берёт последние width
  (свежие не отбрасываются).
- Базлайн батареи 367 ≠ 363 из task.md — батарея доросла чужими дельтами;
  инвариант «все до-этапные ассерты зелёные» соблюдён.
- Интервал <0.05 с — батарейный режим без сна (шов v1); интервал клавишами
  min 1 с.

## Out-of-scope proposals (идеи — сюда, не в код)

- вернуть uptime в строку «Режим» (v1 показывал; пропало по составу v2);
- VRAM/GTT total + бар (читать mem_info_vram_total) — «Память» стала бы
  симметричной RAM;
- swap-строка «Памяти» (у hfctl есть, в ТЗ gfctl не заказано);
- пульс раундов верификации (Δdrafts раундов) отдельным sparkline —
  диагностика качества спекуляции;
- отображение состояния паузы логов в plain-режиме.
