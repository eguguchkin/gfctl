# Brief: 4.5-watch-v2 (переработка watch-дашборда по ТЗ 4.5)

## Goal (статable, checkable)

Заменить watch v1 на v2 по зафиксированному ТЗ `tasks/4/4.5-watch-v2-decision.md`:
блоки «Железо» (GPU/CPU из sysfs, перенос hfctl 1:1), «Память», «Движок»
(вычисляемые показатели из кумулятивных `/metrics` gufo), «Скорость» (sparkline
дельт), «Логи» (`podman logs` без `-t`, TZ-конверсия UTC→локальный пояс в слое
watch). Режимы TUI и plain — оба. Реализация: python-слой (data-heavy), shell
остаётся тонким оркестратором.

## DoD (checklist; единственный носитель DoD)

1. «Железо»: первая карта vendor 0x1002 в `/sys/class/drm/card*`; `temp_c` =
   MAX по всем `temp1_input` ЭТОЙ карты (баг v1 `read_first_temp` — CPU k10temp —
   устранён); `sclk_mhz`, `power_w`, `busy_pct` (card*/device/gpu_busy_percent),
   VRAM/GTT (Б→GiB); CPU `Tctl` (k10temp). Цвета: жёлтый 80–89 °C, красный ≥90.
2. «Память»: RAM MemTotal/MemAvailable (`/proc/meminfo`, GiB) + VRAM/GTT, цвет
   по заполнению.
3. «Движок» — формулы из ТЗ (кумулятивные счётчики!): генерация средняя
   (tokens_predicted_total/…_seconds_total), генерация последнего запроса
   (Δ последнего done), prefill средняя, кэш-эффект % (cached/prompt ×100),
   спекуляция accepted/drafts ×100 (выделенная строка), draft sparkline
   (Δ drafts за тик), KV заполнение % (kv_cache_usage_ratio), KV пик
   (n_tokens_max), очередь (requests_processing/deferred), счётчики всего,
   роут/режим (health + лог configured).
4. «Логи»: БЕЗ `podman logs -t` (время в строках движка), TZ-конверсия в слое
   watch; TUI + plain.
5. Свойства счётчиков учтены: обновление ТОЛЬКО на done → средние в idle
   стабильны; Δ за тик = «пульс завершений» (sparkline), НЕ скорость.
6. Батарея: фикстуры-снапшоты /metrics (стабильные + live-дельты) зелёные;
   существующая батарея не сломана (сейчас 362 ассерта); `bash -n gfctl
   lib/*.sh`; `python3 -m py_compile tpl/python/*.py`.
7. SPEC §3 (строка `watch`) обновлён той же дельтой; `spec_validate` прогнан.
8. BLOCKED-EXTERNAL (не блокирует закрытие подэтапа, уходит в окно этапа 5):
   живой прогон — счётчики движутся, отображение 200, сверка температур с
   `sensors`/hwmon живой машины.

## Specification references + fact/decision ids

- SPEC §3 — карта команд, строка `watch` (v1-описание, заменяется);
  §6 — роут/health (источник роута для блока «Движок»).
- ТЗ: `.dev/tasks/4/4.5-watch-v2-decision.md` — единственный носитель дизайна
  (блоки, формулы, источники, приёмка) — архитектору верифицировать по нему.
- Принцип python/shell: `.dev/tasks/4/4.4-layout-python-decision.md`
  (python = data-heavy; новые data-heavy фичи — только python; shell не
  расширяется). DECISIONS D2 (порт 8080), D6 (живые запуски — только по GO,
  живой прогон НЕ в этом подэтапе).
- Факты: список `/metrics` gufo — факт-база EXP-007 (`.dev/external/
  EXP-007-agentcheck.result.txt` + AGENT-CONFIGS); F14 (машины, hwmon/k10temp);
  F20 (BF16=30 — канон display-имён, к watch не относится, не трогать).
- Существующий код: `lib/commands.sh`/`lib/health.sh` (сбор данных),
  `tpl/python/watch_tui.py` (v1 TUI), `tpl/` юниты — архитектору на чтение.

## Constraints and known traps

- Только stdlib python; никаких новых зависимостей; bash-комментарии по
  конвенции AGENTS.md (рус., «Назначение/Побочные эффекты/…»); один файл = одна
  роль в `tpl/python/`.
- Контейнер не трогать (TZ-конверсия в слое watch, не gufo).
- Ловушка v1: температура — первая попавшаяся `temp*_input` без фильтра по
  карте → на evo/FAEX это CPU. Фильтр по карте ОБЯЗАТЕЛЕН.
- Ловушка счётчиков: кумулятивные, idle-средние стабильны; в работе запрос
  не учитывается (консервативно, как hfctl); не делить Δ секунд на Δ времени
  тика (это не скорость).
- Роут читается из лога `load_completed` (SPEC §6), health-эндпоинт — режим.
- Роль не делает ssh/podman наружу, не коммитит, не правит STATE.md.
- Часы приёма: TTY → TUI (q/+/-/p), не-TTY → стрим; мёртвый сервер — строка
  «недоступен» без спама (сохранить поведение v1).
