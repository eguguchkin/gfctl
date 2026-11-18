# Test report: 3.1 agent-check + cache + watch

- Date: 2026-11-18 / tester, round 1
- База: HEAD 11dbe20 + рабочий лес 3.1 (git status — только ожидаемые файлы:
  M gfctl, M lib/commands.sh, M lib/profiles.sh, M tests/run_checks.sh;
  ?? lib/agentcheck.sh, ?? tpl/python/agent_check.py, ?? tpl/python/watch_tui.py,
  ?? .dev/external/EXP-007-agentcheck.sh, ?? .dev/tasks/3/3.1/dev-report.md;
  brief/task закоммичены оркестратором).

**Verdict: PASS**

## Internal checks

Батарея: `bash tests/run_checks.sh` — **×3 прогона подряд: PASS=289 FAIL=0 rc=0**
(стабильно; было 233, +56 ассертов).

| DoD-пункт (brief/task) | проверка | результат |
|---|---|---|
| §33 cmp_ref/ref_get | cmp_ref 20/23.8→PASS; 28 (граница 29.75)→PASS; 30→WARN «регрессия >25%»; ref=''→WARN «референс не снят (EXP-007)»; hint — только в хвосте WARN-регрессии; ref_get 27b-single: session=23.8 / followup=1.7 / restore=0.81; flash-multi/27b-multi/docq → '' (до EXP-007 WARN) | PASS ×9 (§33) |
| agent-check 4 проверки | §34 faux-прогон через `cmd_agentcheck`: rc 0, сводка **PASS=3 WARN=1 FAIL=0** (docq → WARN «не снят»); ровно **25 chat-POST** (15 сессия + 6 лестница + 2 docq + 2 restore) и **4 CHECK-строки**; порядок по FAUXLOG: warn-рестарт и 24-й POST ДО `podman rm`, 25-й POST после; ровно один `podman run` (container_up); state-файл restore удалён; /metrics не дёргается (тайминги из тела) | PASS ×10 (§34) |
| rc-семантика WARN≠FAIL | §34: WARN=1 → rc 0; **ручной повтор tester'а через реальный диспетчер** (faux PATH + живой TCP-слушатель 8080, curl reuse=none): `FAIL: disk-restore не сработал (reuse=none)` → сводка **PASS=3 WARN=1 FAIL=1, rc 1** | PASS (§34 + ручной) |
| структурный FAIL | §34a: curl FAILALL → die rc 1 ДО сводки; timings нет в ответе → rc 1 «timings отсутствует — проверь ревизию gufo»; контейнер не running → die (гейт) | PASS ×3 (§34a) |
| cache: parse_configured + сводка | §35: две configured — ПОСЛЕДНЯЯ побеждает (sessions/capacity/disk/ram_cache/automatic; `\b`-граница — capacity не ловит disk_capacity); нет строки → «не настроен», rc 0; счётчики skipped/evicted count-only; /metrics cached_total=539 через faux curl; /metrics отказ → «?» rc 0 (не-фатально) | PASS ×8 (§35) |
| cache --verify | §36: reuse=live→PASS + рестарт reuse=disk→PASS (rc 0, ровно 3 chat-POST); порядок «2 POST < warn-рестарт < podman rm < restore-POST»; state cache-verify.json удалён; **reuse=none → die rc 1 ДО рестарта** (`podman rm` не вызывался) с подсказкой --cache-ram-bytes | PASS ×6 (§36) |
| tmpfs-детект | §36: faux `stat` GFCTL_FAUX_STAT_FSTYPE=tmpfs → WARN «disk-тир переживает только до ребута» (DoD PLAN); ext4 → WARN нет (негатив) | PASS ×2 (§36) |
| watch не-TTY | §37: GFCTL_WATCH_TICKS=1 → rc 0, блоки [движок]/[скорость]/[память] (модель «Qwen3.8 Flash Next» с пробелами из сида, cached_total 539, сырые llamacpp:*, meminfo+hwmon); счётчик /metrics-вызовов = тикам (1); **мёртвый сервер TICKS=3 → ровно 3 строки «недоступен», без traceback**; /metrics = 3; сид логов один; через диспетчер `gfctl watch` → exec python → rc 0 | PASS ×11 (§37) |
| TUI-ветка (selfcheck) | `GFCTL_WATCH_SELFCHECK=1` → **24/24 ok**, rc 0 (парсер/рендер-скелет без curses); клавиши q/Q/+/(=)/-/(_)/p в коде (watch_tui.py:613–619); isatty-выбор режима | PASS (ручной) |
| заглушки сняты РОВНО у 3 | §2: роутер — die-ветка этапа 3 исчезла → `watch) cmd_watch` / `cache) cmd_cache` / `agent-check) cmd_agentcheck`; цикл «не-заглушка» расширен до 12 команд (watch/cache/agent-check — живые, timeout, без «появится в сабстэдже»); грамматика 5 форм (watch --interval abc/0, watch bogus, cache extra, cache --verify extra → die); usage-строки остальных команд байт-в-байт | PASS (§2) |
| usage без «[этап 3]» | `./gfctl --help` → 0 вхождений «[этап 3]»; help rc 0; bare rc 1; garbage rc 1 | PASS (ручной) |
| регресс 1.1+1.2+2.1 | полный прогон зелёный ×3 (289); **git diff старых секций — по содержимому нетронуты** (минус-строки только: шапка faux-curl, §2-замена заглушек по п.0-прецеденту — разрешено brief'ом); пины весов целы (models.sh не в diff: `ea5a3c45…`/`1a25c568…`, размеры 14534384640/1143006816 = SPEC §5); md5 фикстуры `253c7ac5…` (F12); WARN probe_context «тихое урезание» (commands.sh:482) НЕ тронут (замечание review-f4 — бэклог, не скоуп 3.1); SPEC/PLAN/models/serve — в diff отсутствуют | PASS |
| AGENTS internal checks | `bash -n gfctl lib/*.sh` OK; `python3 -m py_compile tpl/python/*.py` OK; `./gfctl` bare → usage rc 1; `GFCTL_PORT=8199 ./gfctl status --json` → rc 0, JSON валиден (мёртвый порт) | PASS (ручной) |
| запреты (IP/хосты/ключи) | grep по lib/ tpl/ gfctl tests/ EXP-007: только канон 0.0.0.0/127.0.0.1/ghcr.io — реальных IP, имён машин, путей ключей нет | PASS |
| EXP-007 заготовка | `bash -n` OK; **не исполнялась** (result-файла нет — D6); hosts/ключи только через env (GF_ACC_HOST/USER/KEY/FLAVOR, `:?`-гейты); **bootstrap-first** (install.sh — первый шаг remote-части, урок F21); PASS-критерии: agent-check rc 0 + блок REFS (числа = новые референсы flash-multi; evo — против 23.8/1.7/0.81) + cache --verify + факт-база (полный список llamacpp:*, образцы event=skipped/evict*) + TIMINGS_OK; в конце `gfctl off` (дорога hfctl on) | PASS |

**Отклонение curl-vs-urllib: ПОДТВЕРЖДЕНО** (dev-report «Known limitations» —
транспорт python = curl из PATH вместо буквы Design §3 «curl-независимый
python urllib»). Сверка с task.md дословно:

- Test strategy §A (строка «agent-check 4 проверки»): «детерминированный прогон
  … (**faux curl** с `timings`+`component_cache` …): **ровно 25 chat-POST** …,
  порядок … по FAUXLOG» — счёт POST возможен ТОЛЬКО если запросы идут через
  curl из PATH (faux-шов); urllib их бы миновал.
- Хвост Test strategy: «флаг `GFCTL_FAUX_CURL_TIMINGS=1` добавляет в
  chat-ответ … (значение reuse сценарится `GFCTL_FAUX_CURL_REUSE`, **счётчик
  тот же GFCTL_FAUX_CNT.curl**)» — общий счётчик явно предписан (§D: «счётчик
  /metrics-вызовов = тикам» — тот же .curl).
- Risks: «каждый запрос ограничен **-m 1200**» — curl-флаг (agent_check.py:125:
  `["curl","-fsS","-m","1200",…]` — 1:1).
- Формулировка Design §3 «urllib» — внутреннее противоречие task.md; опертивная
  секция для проверок — Test strategy, батарея построена ровно по ней и зелёная
  (25 POST, timings-флаг, общий счётчик работают). Стандартные ограничения не
  пострадали: subprocess — stdlib, «один файл = одна роль» соблюдён, конверт
  запроса байт-в-байт протокола окон, ROUTE_MODEL с пробелами — одно значение
  argv/json.dumps.

## Failures (FAIL)

Нет.

Примечание (не блокер, бэклог батареи): вердикт-ветку agent-check
«reuse=none → FAIL» §34/§34a напрямую не ассертит (Test strategy §A2 требовала
только структурные FAIL; reuse=none ассертился для cache --verify, §36) —
закрыто ручным повтором tester'а через реальный диспетчер (см. таблицу).
Стоит добавить ассерт в §34 при следующем касании батареи.

## External experiments (BLOCKED-EXTERNAL)

| EXP-id | DoD-пункт | статус |
|---|---|---|
| EXP-007-agentcheck | DoD 3.1 п.6 (заготовка окна этапа 3, не исполняется — D6) | **created** (очередь; GO пользователя) |
| EXP-007 (сценарий) | PLAN этап 3: живой agent-check на flash-multi 2×262144 (4 пункта PASS) и на 27b-single evo (против 23.8/1.7/0.81) | в EXP-007, ждёт GO |
| EXP-007 (сценарий) | PLAN этап 3: живой cache --verify — follow-up reuse, рестарт-проба reuse=disk, живой `stat -f %T` кэш-каталога (tmpfs→WARN) | в EXP-007, ждёт GO |
| EXP-007 (сценарий) | watch TUI на SSH-TTY: клавиши q/+/-/p живьём (батарея покрывает plain + selfcheck-скелет) | в EXP-007, ждёт GO |
| EXP-007 (сценарий) | контракт `timings`/`component_cache.reuse` живого gufo + факт-база: полный список `llamacpp:*`, форматы event=skipped/evict* → затем заполнение `ref_*` в lib/profiles.sh + AGENT-CONFIGS (куды писать: task.md Out of scope «заполнение референсов (после окна)»; brief: «константы в profiles/AGENT-CONFIGS») — сверено, согласовано | в EXP-007, ждёт GO |

Внешние EXP по инструкциям НЕ исполнялись. Все BLOCKED-EXTERNAL пункты DoD
остаются открытыми до окна — это ожидаемое состояние сабстэджа (аналог
этапов 1–2).

## Regression

- `bash tests/run_checks.sh` ×3 → **PASS=289 FAIL=0 rc=0** (полная батарея
  1.1+1.2+2.1+3.1; счётчик стабильен от прогона к прогону).
- `bash -n gfctl lib/*.sh` OK; `python3 -m py_compile tpl/python/*.py` OK;
  `bash -n .dev/external/EXP-007-agentcheck.sh` OK.
- Пины весов (F8/SPEC §5), md5 фикстуры bench (F12), SPEC.md/PLAN.md,
  probe/bench/check-types/status — не тронуты (git diff); WARN probe_context
  не переформулирован (правильно: бэклог F21, не скоуп 3.1).
- Гигиена: faux-bin/HOME-песочница батареи — следов в реальном home/репо нет;
  живые машины не трогались.
