# Task: 2.1 probe-подбор контекста + gfctl bench — Design: architect

## Scope and DoD

**In scope** (2 механики этапа 2, обе локально тестируемые через faux-bin):
1. `probe_context(профиль, sessions)` — перебор лестницы контекста из поля 8
   профильной таблицы; первая загрузившаяся ступень = канон пары.
2. Канон per (профиль × sessions) в `~/gufo/.env` — совместимо с форматом 1.2.
3. Интеграция в `cmd_use` (включая `--no-probe`, `--context`, `--sessions`).
4. `cmd_bench` — фиксстура `tpl/bench/merge_sort_thinking_off.txt` (md5
   `253c7ac5…`, НЕ редактировать) ×3 по HTTP + прогрев, wall + completion
   tok/s + медиана.
5. Батарея `tests/run_checks.sh`: осознанные замены секций §2/§14/§18 + новые
   секции probe/bench; остальной регресс 1.1+1.2 (180+ ассертов) не тронут.

**Out of scope** (не делать в этом сабстэдже): `watch`/`cache`/`agent-check`
(этап 3, остаются заглушками); `models --check-types` на UD-шардах (этап 2,
другой сабстэдж); парный агрегат-замер bench (EXP-004-стиль — отдельная
история, bench = одиночный запрос); ротация probe-журнала; force-re-probe
флаг (спек §9: канон выигрывает); vision/8-16 потоков (бэклог).

**DoD** — из brief 2.1 (единственный носитель DoD): попытки по лестнице с
журналом; повторный use = ровно одна загрузка; `--no-probe` = WARN +
канон/минимальная ступень; канон (flash-multi,4) не затирает (flash-multi,2);
все ступени отказали → die с таблицей попыток; bench ×3 + сводка + md5-гейт +
мёртвый порт → rc≠0; internal checks зелёные, регресс цел; EXP-005-faex /
EXP-006-evo-probe поставлены в очередь (не исполняются).

## Design

### 1. Канон per (профиль × sessions) — `lib/state.sh`

**Формат**: плоские ключи в том же `$STACK_DIR/.env`:
`GFCTL_CTX_<профиль>_<sessions>=<context>`, где `<профиль>` — id с заменой
дефисов на подчёркивания (`27b-multi` → `27b_multi`). Пример:
`GFCTL_CTX_27b_multi_2=163840`.

Обоснование: (а) тот же grep-парсинг, что у всех ключей канона (canon_get);
(б) нормализация дефисов делает имя валидным bash-идентификатором —
`canon_get` с indirect-раскрытием `${!key}` и process-env-оверрайд работают
без изменений механизма; (в) один файл = один канон, boot/watchdog читают
старые ключи как раньше.

**Чтение — `canon_pair_context(prof, sessions)`** (новая, приоритет
однозначный):
1. `canon_get GFCTL_CTX_<norm>_<sessions> ""` непусто → оно
   (env-оверрайд > .env — механика canon_get без изменений);
2. иначе 1.2-совместимость («миграция чтением»): `GFCTL_PROFILE == prof` И
   `GFCTL_SESSIONS == sessions` в каноне → `GFCTL_CONTEXT`
   (канон EXP-004/1.2 продолжает работать как канон пары);
3. иначе пусто (канона пары нет → probe).

**Запись — расширение `write_canon(prof, sessions, context)`** (сигнатура
не меняется, остаётся ЕДИНСТВЕННЫМ писателем .env): рендер env.tpl →
.env.tmp как в 1.2; затем к .env.tmp дописываются: все строки
`^GFCTL_CTX_` из старого .env КРОМЕ ключа этой пары + актуальная строка
`GFCTL_CTX_<norm>_<sessions>=<context>`. mv — атомарность как в 1.2.
env.tpl не меняется; при отсутствии пар-ключей .env байт-в-байт равен
рендеру 1.2 (свежий install не отличается). Каждое успешное use пишет
ОБА представления: активные поля шаблона (GFCTL_PROFILE/SESSIONS/CONTEXT)
и пару-ключ — читатели 1.2 и новое чтение согласованы всегда.

**Ключевое решение — probe НЕ пишет канон между попытками**: попытка
запускается env-оверрайдом `GFCTL_SESSIONS=$s GFCTL_CONTEXT=$step
container_up "$prof"` (canon_get: env > .env > таблица — механика уже
умеет). Итог: канон на диске не изменяется ни при отказе попытки, ни при
отказе всего probe (свойство отката: старый канон цел; вотчдог/boot после
смерти probe поднимут прежнее). При `--sessions 4` лестница НЕ меняется —
оверрайд меняет только admission (SPEC §5: «та же лестница на 4 сессии»).

### 2. probe-механика — `probe_context(prof, sessions)` в `lib/commands.sh`

(командная оркестрация container_up+wait_load; отдельный модуль не нужен —
в диспетчере фиксированный список source, не раздуваем).

```
probe_context(prof, sessions):
  ladder=$(profile_field prof 8); ladder='-' → return 1 (не зовётся)
  journal="$LOGS_DIR/probe-${prof}-${sessions}.log"; mkdir -p $LOGS_DIR; : > journal
  for step in $ladder:                       # по убыванию, как в поле 8
    probe_log "ступень $step: попытка загрузки (sessions $sessions)"
    if GFCTL_SESSIONS=$sessions GFCTL_CONTEXT=$step container_up "$prof" \
       && wait_load 180; then
      PROBE_CTX=$step                        # глобал, как ROUTE_* в health.sh
      probe_log "ступень $step: OK — канон"
      return 0
    fi
    verdict = podman logs | grep -q load_failed ? "load_failed (admission/отказ загрузки)" : "таймаут 180с"
    probe_log "ступень $step: ОТКАЗ — $verdict"
  # все ступени отказали:
  печать в stderr таблицы попыток (построчно из journal) +
  die "probe: все ступени лестницы отказали (профиль $prof × sessions $sessions) —
       это тоже результат (PLAN); задай контекст явно: gfctl use $prof
       --sessions $sessions --context N"
```

- `probe_log()` = строка в journal (append) + та же строка в stdout («ступень
  X: …» — прогресс худшего случая 94 с × 5, F5).
- Пауза F10 между попытками — переиспользуется встроенная пауза
  container_up (GFCTL_RECREATE_PAUSE_S + ретраи run).
- Вердикты попытки: `load_failed` (ранний выход 20 с, GFCTL_LOADFAIL_AFTER —
  решено в 1.2, переиспользуем), `таймаут` (180 с), `успех` (load_completed в
  логе; критерий — wait_load, «загрузилась»; /ready+smoke идут в общем флоу).
- Отказ podman run за GFCTL_RUN_ATTEMPTS (занятый порт и т.п.) — это
  infra-отказ, не вердикт лестницы: container_up сам die (процесс завершён,
  повтор use). В таблицу попыток не попадает.

**Успех без второго recreate**: канон пары уже сработал (env-оверрайд дал
байт-в-байт ту же serve-строку, которую записал бы write_canon), поэтому
cmd_use на probe-пути НЕ вызывает container_up повторно: write_canon →
wait_health (route уже в логе → мгновенно) → smoke. Экономия до 94 с
загрузки (F5) на каждой probe-попытке. Инвариант «канон на диске == конфиг
работающего контейнера» сохраняется — это фиксируется в батарее.

### 3. Интеграция в `cmd_use` (замена тела 1.2 после ensure_weights)

Дерево решений (одно, без веток «по настроению»):

```
sessions = override --sessions или поле 3 таблицы
--context N задан        → ctx=N; log «контекст задан явно — probe пропущен»
иначе ctx=$(canon_pair_context prof sessions):
  ctx непуст и нет --no-probe → log «канон пары (prof×sessions): ctx=N — probe пропущен»
  ctx непуст и --no-probe     → WARN «--no-probe: беру канон пары N»
  ctx пуст и --no-probe       → WARN «канона пары нет — беру минимальную ступень
                                лестницы <последняя>» ; ctx=последняя ступень
                                (лестница '-' → поле 4, как 1.2)
  ctx пуст, лестница '-'      → ctx=поле 4 (27b-single, как 1.2)
  иначе                       → probe_context; ctx=$PROBE_CTX
write_canon prof sessions ctx          # + пара-ключ (см. §1)
probe-путь: контейнер УЖЕ поднят (env-оверрайд) → сразу wait_health 180 → smoke
остальные пути: container_up → wait_health 180 → smoke (порядок 1.2)
печать канона (строка 1.2 без изменений)
```

- `--no-probe` → WARN всегда (униформно, честно «проверка пропущена»);
  результат явно фиксируется в каноне (и пара-ключ) — повторный use без
  флага получит его из канона, перебора не будет.
- Повторный use с существующим каноном пары: ровно ОДНА загрузка
  (container_up единственный), пере-перебора нет — DoD-пункт.
- `use 27b-single --no-probe` — прежнее поведение 1.2 (WARN + таблица):
  секция §18 батареи остаётся зелёной без правки.

### 4. `cmd_bench` — `lib/commands.sh` (заглушка снимается)

Протокол окон взят буквально из `llm-lab/scripts/remote/_bench_arms.sh`
(фикстура мерится как raw-промпт, greedy, thinking off зашит в байтах
фикстуры `<think>\n\n</think>`): **1 прогрев + 3 замера, max_tokens 256,
temperature 0, одиночный запрос** (не параллелить — brief).

```
cmd_bench:
  container_state = running?  нет → die «подними: gfctl on/use»
  port_open canon_port?       нет → die «порт … мёртв — gfctl on/use»
  parse_route < podman logs; ROUTE_MODEL пуст → die «модель не загружена — gfctl use»
  md5-гейт: md5sum "$TPL_DIR/bench/merge_sort_thinking_off.txt"
            == 253c7ac50857fe6d0e10fb0d2c5e35c0
            иначе die «фикстура bench изменена — сравнимость прогонов потеряна (F12)»
  для каждого из 4 запросов (прогрев + 3):
    body: python3 (stdlib json.dumps) читает фикстуру со stdin → JSON
          {"prompt": <байты фикстуры как есть>, "model": ROUTE_MODEL,
           "max_tokens": 256, "temperature": 0} | curl -fsS -m 300 -d @-
    wall = date +%s.%N вокруг curl (GNU-машины); ответ во временный файл
    прогрев: только wall-печатка; замер: usage.completion_tokens из ответа
             (python3-парс) → «прогон N: wall X.Xs | M tok | Y.Y tok/s»,
             tok/s = completion_tokens / wall
    отказ curl / битый JSON / пустой usage → die (без ретрая: ретрай = другая
    нагрузка, честный замер теряется)
  медиана: 3 значения tok/s и wall → средние элементы (`sort -n | sed -n 2p`)
  сводка: «медиана: wall X.Xs | Y.Y tok/s»
```

- Эндпоинт: `POST /v1/chat/completions` подтверждён на gufo (EXP-004,
  http=200), но raw-фикстура через чат-шаблон теряет семантику thinking-off
  (двойной ChatML) → ломает сравнимость с каноном 76.9 t/s (F12). Решение:
  `POST /v1/completions` с prompt = байты фикстуры как есть — литеральный
  аналог `--prompt-file` bench_arms; транспорт изолирован в одной функции
  `bench_request` (смена эндпоинта при fallback — правка одной функции,
  см. OQ-1).
- Временные файлы (body не пишем — пайп; ответ) — mktemp под `$TMPDIR`,
  cleanup trap'ом.

### 5. Диспетчер и usage

- Роутер: `bench` уходит из die-ветки заглушек (`watch|cache|agent-check`
  остаются) → `cmd_bench "$@"`; строка usage `bench` теряет пометку
  `[этап 2]`.
- Тексты cmd_use/probe — русский, в стиле log/warn/die; комментарии функций
  по конвенции AGENTS (@param/@stdout/@returns).

## Test strategy

| DoD item | internal check (faux-bin, батарея) | external (EXP) |
|---|---|---|
| Лестница 27b-multi: 196608 fail → 163840 ok | new §: сценарий `GFCTL_FAUX_CTX_LOGS="196608:LOGFAIL 163840:LOGOK"` → rc 0, канон `.env` = 163840, journal содержит обе строки «ступень …», run-линии faux-лога содержат `--context 196608` затем `--context 163840`, пар-ключ `GFCTL_CTX_27b_multi_2=163840` | EXP-006-evo-probe: живой probe до 196608/163840 с admission-цифрами |
| Лестница flash: 262144 fail, 229376 fail, 196608 ok | new §: тот же меха на flash-multi → канон 196608 | EXP-005-faex: полная лестница 2-сессий + floor-цифры |
| Все ступени fail → die + таблица | new §: все ctx → LOGFAIL → rc 1, stderr содержит «ступень N — <причина>» для каждой + подсказку `--context`; .env НЕ изменился (пар-ключа нет, старые поля целы) | «отказ лестницы — тоже результат» (PLAN DoD flash) |
| Повторный use = одна загрузка | new §: после сценария «fail→ok» повторный use с LOGOK → ровно 1 podman run (Δ=1), в выводе «probe пропущен» | EXP-006: повторный use без перебора |
| `--no-probe` | new §: без канона → WARN + ровно 1 run с `--context 131072` (последняя ступень) + пар-ключ записан; с каноном → WARN + канон, 1 run; `use 27b-single --no-probe` — прежний ассерт §18 (WARN, rc 0) без правки | — |
| sessions 4 изоляция канона | new §: `use flash-multi --sessions 4` (faux: 262144 ok) → run-линия содержит `--sessions 4 --context 262144`; `.env` сохранил `GFCTL_CTX_flash_multi_2=…` И добавил `GFCTL_CTX_flash_multi_4=…` | EXP-005-faex: 4-сессионная лестница, floor 4×65536 ≥60 агрегат |
| Канон 1.2-совместимость | правка §14: .env = env.tpl + блок пар-ключей; fresh write_canon без пар — байт-в-байт как 1.2; upsert не дублирует; чужие пары сохраняются; 1.2-формат .env (без пар-ключей) читается fallback'ом на GFCTL_CONTEXT; env-оверрайд пары > .env | evo после апдейта: EXP-004-канон (GFCTL_CONTEXT=163840) читается как канон пары без перебора |
| bench ×3 + сводка | new §: faux curl ветка `/v1/completions` (детерминированный JSON с usage, счётчик) → ровно 4 вызова (1 прогрев + 3), каждая строка «прогон N: wall … | … tok | … tok/s», строка «медиана:», rc 0 | EXP-005/006: живые числа bench в result-файлах |
| bench мёртвый порт | new §: без слушателя → rc 1 + «gfctl on/use» | — |
| md5-гейт | new §: gf-харнес с TPL_DIR=копия tpl с подправленной фикстурой → die «фикстура … изменена»; канон в репо не мутируется | — |
| bench битый ответ | new §: GFCTL_FAUX_CURL_FAILALL=1 → die rc 1 (без ретрая, 1 вызов до отказа) | — |
| Регресс 1.1+1.2 | все нетронутые секции зелёные (180+ ассертов); `bash -n`, `py_compile` | reviewer прогон батареи |

**faux-bin расширения** (только тестовый код, `tests/run_checks.sh`):
1. faux `podman run` извлекает `--context <N>` из args → текущий ctx в
   файл-состояние; faux `podman logs` со сценарием
   `GFCTL_FAUX_CTX_LOGS="196608:<file> 163840:<file>"` возвращает файл по
   текущему ctx (нет маппинга/ctx → старый GFCTL_FAUX_PODMAN_LOGS — старые
   тесты не меняются). Механика детерминирована args'ами run, а не счётчиком
   вызовов — wait_load сам поллит logs много раз, счётчик разъезжался бы.
2. faux curl: ветка `*/v1/completions*` → JSON
   `{"choices":[{"text":"…"}],"usage":{"completion_tokens":256}}`; отказы —
   существующие FAILFIRST/FAILALL.

**Осознанные замены секций батареи** (п.0 конвенция 1.2): §2 (список
заглушек `watch cache agent-check`; bench → живая), §14 (ожидание .env с
пар-блоком + новые pair-ассерты), §18 (--no-probe на multi-сценариях;
happy-path `--context` остаётся). Остальное — только добавление секций.

## Risks and rollback

- **`/v1/completions` на gufo не подтверждён факт-базой** (chat — да,
  EXP-004). Первый прогон EXP-005/006 проверяет эндпоинт первым делом;
  fallback = `bench_request` на chat+`chat_template_kwargs` (правка одной
  функции, числа канона теряют прямую сравнимость — фиксируется в FACTS).
  Risk-уровень: низкий (gufo — llama.cpp-семейство, эндпоинт стандартный).
- **Имя события отказа**: вердикт `load_failed` опирается на design-константу
  1.2 (F17: живьём не наблюдался). Если admission-отказ gufo пишет не
  `load_failed`, probe не умрёт — ступень завершится таймаутом 180 с и
  лестница продолжится (медленнее, корректно). Уже есть seam
  GFCTL_LOADFAIL_AFTER. Факт после EXP-006 — в FACTS.
- **write_canon — самая горячая функция** (boot/watchdog/install/use):
  расширение может слить пар-ключи при гонке двух писателей — гонка вне
  модели отказа (однопользовательский CLI), атомарность mv сохранена.
  Регресс-страхование: §14 + §17/§18/§20 зелёные.
- **EXP-006 ловушка канона**: на evo уже стоит 1.2-канон 27b-multi×2
  (GFCTL_CONTEXT=163840, EXP-004) — по спеку §9 канон выигрывает, probe не
  запустится. EXP-006-скрипт ОБЯЗАН сбросить канон пары (rm/sed строки
  `.env`) перед use — это фиксируется в DoD заготовки EXP-006 (ставит tester).
- **Худший случай probe flash** = 5 × (94–180 с) + паузы ≈ 8–16 мин —
  ограничено таймаутами, прогресс печатается по ступеням (не hang);
  интерактивный пользователь видит движение.
- **Откат**: git revert сабстэдж-коммита; формат .env с лишними
  `GFCTL_CTX_*` строками читается старым кодом 1.2 безвредно (grep-парсинг
  игнорирует неизвестные ключи) — данные не портятся, миграция вниз не
  нужна.

## References

- SPEC §1 п.6 (probe-максимум, кэш результата в профиле), §3 (use/bench), §5
  (лестницы 196608→163840→131072 / 262144→…→131072, «та же лестница на 4
  сессии», floor-точки), §9 (цена probe, кэш в каноне).
- PLAN этап 2 (DoD flash: probe ≥196608 ИЛИ зафиксированный отказ; bench).
- FACTS: F5 (flash ~94 с), F6 (floor 2×131072=56.1, 4×65536=77.3), F7
  (163840 на Q4_K_XL, 196608 впритык), F8 (пины), F10 (пауза recreate), F12
  (фикстура md5 253c7ac5 — единственный честный A/B), F13 (admission-отказ
  2×262144 — старт лестницы 196608), F16/F11 (маркер/linger не трогаем),
  F17 (load_failed-порог — design-константа), F18 (27b-multi живой на evo,
  канон 163840 стоит).
- DECISIONS: D4 (flash только мульти), D5 (27b-multi 163840, probe 196608
  первый кандидат).
- Код: lib/profiles.sh (поле 8), lib/state.sh (canon_get/write_canon),
  lib/serve.sh (container_up: env-оверрайд canon_* — носитель попыток),
  lib/health.sh (wait_load/wait_health/smoke/parse_route), lib/commands.sh
  (cmd_use/cmd_smoke как образцы), tests/run_checks.sh (faux-bin, §14/§18),
  gfctl (роутер/usage); референс протокола bench: llm-lab
  scripts/remote/_bench_arms.sh (+EXP-004 в gfctl .dev/external).

## Open questions

1. **Эндпоинт bench** (неблокирующий): (a) `POST /v1/completions`, prompt =
   байты фикстуры как есть — сравнимость с каноном 76.9 t/s полная
   (рекомендую, принято в Design); (b) chat/completions +
   `chat_template_kwargs` — эндпоинт подтверждён, но prompt ≠ байты фикстуры
   (канон теряется). План: разработчик делает (a); EXP-005/006 проверяют
   эндпоинт первым действием; 404/4xx → fix-round переключает на (b) правкой
   `bench_request` + запись факта в FACTS.
2. **Лестница при sessions=4** (неблокирующий): минимум лестницы 131072 — на
   4 сессиях вся лестница может отказать admission'ом (проверен только floor
   4×65536, F6; в поле 8 ступени 65536 нет). (a) та же лестница, полный
   отказ → die с подсказкой ручного `--context 65536` — соответствует SPEC §5
   «та же лестница», отказ честный и «тоже результат» (рекомендую);
   (b) добавить 65536 хвостом лестницы flash при sessions>2 — требует правки
   SPEC §5 в том же дельта и факта живого прогона (сейчас 65536 не в
   лестнице). Решаем (a); если EXP-005 покажет полный отказ 4-сессионной
   лестницы — правка SPEC §5 (хвост 65536) отдельным дельта по факту.
3. **`--context` + `--no-probe` вместе** (неблокирующий): явный `--context`
   сильнее `--no-probe` (контекст задан — перебор неуместен), WARN от
   `--no-probe` всё равно печатается. Рекомендую именно так (меньше кода,
   флаги независимы); альтернатива — die на комбинации (строже, но больше
   кода без пользы).
