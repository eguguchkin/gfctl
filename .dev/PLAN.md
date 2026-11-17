# План реализации спецификации gfctl (`.dev/SPEC.md`, v2)

Статус: DRAFT 2026-11-17 (решения пользователя: локальная дистрибуция,
порт 8080, takeover не нужен, flash — только мульти с probe-максимумом
контекстов). Четыре этапа, каждый — отдельным коммитом с приёмкой перед
следующим (этап 1 — evo 60 GiB; этапы 2–4 — FAEX 128 GB + повтор на evo).
Откат этапа = git revert до начала этапа.

Общие правила:
- живой прод на машине останавливается только внутри приёмки этапа
  (`hfctl off` до окна, `hfctl on` после, healthy + smoke по завершении);
- каждая смена конфига — recreate + wait_health + smoke (порядок
  фиксированный);
- приёмка — EXP-скрипты в llm-lab, GO пользователя на каждое окно;
  числа — в llm-lab BENCH.md и AGENT-CONFIGS.md.

---

## Этап 1 — CLI-грамматика, профиль 27b-single, автоподнятие (evo)

### Что делается
1. Диспетчер `gfctl` + `lib/` (profiles, models, serve, state, health,
   autostart, util, ui) + `tpl/` (systemd serve/boot/watchdog, env-шаблон).
   Профильная таблица: `27b-single` (pure-IQ4_XS + dflash2, sessions 1,
   ctx 262144, cache-ram 12G, cache-disk 64G) — SPEC §5.
2. Команды: `install [--profile] [--port]`, `use`, `on/off`, `status
   [--json]`, `logs`, `uninstall`, `doctor`, `models`. Скрытые алиасы
   `up|down`.
3. Models-модуль: сеты pure-IQ4_XS + DFlash2 draft с sha256-пинами;
   pre-flight «нужно X GiB свободно», докачка curl с прогрессом.
4. Preflight-гейты: ОС, /dev/kfd+renderD, render-группа, memlock (limits.d,
   ребут exit 42), linger, RAM-гейт ≥56 GiB, порт, gpu-lock WARN.
5. Watchdog-паттерн hfctl: timer 1 мин → `gfctl _watchdog` → up, если нет
   маркера `.gfctl-stopped`; boot-юнит поднимает канон профиля.
6. `gfctl smoke` (health + 3 запроса + роут из лога).

### DoD (evo) — ВЫПОЛНЕН (окно 2026-11-17, EXP-001/002/003 PASS; result-файлы в .dev/external/)
- [x] `gfctl install` на голом каталоге: веса докачаны (sha PASS), healthy,
      smoke OK, роут `dflash2 sessions 1 ctx 262144`, автозапуск вкл.
- [x] `off`: стоп+disabled+linger off, вотчдог не воскрешает (70 c);
      `on` — всё вернулось.
- [x] Ребут-приёмка: сервер сам healthy после загрузки, ручных команд 0.
- [x] `status --json` валиден; `doctor` печатает гейты всех профилей
      (flash-multi = НЕДОСТУПЕН на 60 GiB с цифрами).
- [x] `bash -n` / `py_compile` / usage rc=1 / status при мёртвом порте —
      зелёные.

⚠️ Пункт «Ребут-приёмка» живым ребутом в окне НЕ проверялся (ребут evo —
вне окна приёмки): проверен эквивалент — boot-юнит поднимает канон после
полного останова юнитов + старта через systemctl (EXP-003 «on»);
живой ребут — бэклог до этапа 4 (финальные ребут-приёмки обеих машин).

---

## Этап 2 — мульти-профили + probe-подбор контекста + bench (FAEX)

### Что делается
1. Профиль `27b-multi`: sessions 2, **probe-лестница 196608 → 163840 →
   131072** (floor 163840 проверен окном G8–G12 на Q4_K_XL; на IQ4_XS запас
   больше), cache-ram 4 GiB. Найденный контекст фиксируется в каноне.
2. Профиль `flash-multi` (единственный flash): sessions 2, **probe-лестница
   262144 → 229376 → 196608 → 163840 → 131072** (floor 131072 проверен
   окном FX: агрегат 56.1), cache-ram 4 GiB; `use flash-multi --sessions 4`
   — та же лестница на 4 сессии (floor 65536, агрегат 77.3). Каждая
   попытка логируется; загрузившаяся = канон.
3. `gfctl bench` (фикстура `253c7ac5` ×3) + `gfctl models --check-types`
   (gguf-парсер из tpl/python; регресс-тест правила UD-*).
4. **Пере-снятие агентских референсов flash-multi** (окно FX мерило
   соло-конфиг): `agent-check`-сценарии (сессия 15 ходов, follow-up 25k,
   [док][q]) на итоговой probe-конфигурации → числа в AGENT-CONFIGS.

### DoD (FAEX)
- [ ] `use 27b-multi`: роут `dflash2 sessions 2 ctx 163840` (или 196608,
      если probe прошёл), 2-пар ≥25 агрегат (референс 29.5 ±15%).
- [ ] `use flash-multi`: probe доходит до ≥196608 ИЛИ фиксируется отказ
      262144/229376 с цифрами admission-лога (это тоже результат);
      floor-вариант 2×131072 = агрегат ≥45 (референс 56.1 ±20%).
- [ ] `use flash-multi --sessions 4`: лестница на 4 сессии, floor 4×65536
      агрегат ≥60 (референс 77.3 ±20%).
- [ ] Агентские референсы flash-multi записаны в AGENT-CONFIGS (сессия,
      follow-up, [док][q]).
- [ ] `models --check-types` на UD-IQ4_XS flash-next: КРАСНЫЙ (регресс-тест
      правила окон IX/FX).
- [ ] RAM-гейт flash-multi на evo: отказ ДО трафика.
- [ ] use×3 подряд без утечек порта/памяти; статус честный после каждого.

---

## Этап 3 — `agent-check` + `cache` + watch

### Что делается
1. `gfctl agent-check` (SPEC §7): сессия 15 ходов, follow-up-лестница,
   [док][q], рестарт-restore; референсы из AGENT-CONFIGS (±25% → WARN с
   подсказкой причины).
2. `gfctl cache [--verify]`: сводка из логов + `/metrics`; `--verify` —
   follow-up + рестарт-проба (tmpfs-каталог → WARN).
3. `gfctl watch` (TUI + plain): /metrics gufo + host sysfs + логи.

### DoD (FAEX + evo)
- [ ] `agent-check` на flash-multi: 4 пункта PASS; искусственная регрессия
      (cache-ram 512MiB) → WARN follow-up ловится.
- [ ] `agent-check` на 27b-single (evo): PASS (референс 23.8 с).
- [ ] `cache --verify` ловит кэш на tmpfs (WARN).
- [ ] watch TUI на SSH-TTY (q/+/-/p), не-TTY стрим; мёртвый сервер — строка
      «недоступен» без спама.

---

## Этап 4 — хардening, локальная доставка, приёмка на обеих машинах

### Что делается
1. Uninstall-слои, идемпотентность install поверх работающего, учёт
   «ручных» артефактов окон (~/gufo-models, ~/gufo-exp, ~/halogen-models,
   ~/halogen-cache) в doctor.
2. Локальная доставка: перенос каталога (rsync/scp) + install.sh с нуля
   на обеих машинах (EXP): uninstall→перенос→install→healthy→agent-check.
3. Ребут-приёмки обеих машин; финальный STATE: прод-статусы восстановлены
   (evo: hfctl 27b-single healthy; FAEX: hfctl flash-multi healthy).

### DoD
- [ ] Полный цикл с нуля на обеих машинах (EXP-логи в llm-lab external/).
- [ ] Ребут: gfctl-сервер сам healthy; hfctl-прод после `hfctl on` —
      healthy, smoke OK.
- [ ] README.md (quickstart), AGENTS.md актуальны, git чистый.
- [ ] Бэклог-хвосты в STATE.md: `--with-vision` (mmproj), 8–16 потоков
      (CONC-зона gufo), COMPOSABLE-аналог, авто-переход 27b-multi↔single.
