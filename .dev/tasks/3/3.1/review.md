# Review: 3.1 agent-check + cache + watch

Verdict: **APPROVED**
Round: 1

Собственный прогон (reviewer, 2026-11-18, HEAD 11dbe20 + рабочий лес 3.1):
`bash tests/run_checks.sh` ×2 → **PASS=289 FAIL=0 rc=0** (оба прогона);
`bash -n gfctl lib/*.sh` OK; `python3 -m py_compile tpl/python/*.py` OK;
`GFCTL_WATCH_SELFCHECK=1` → 24/24 rc 0; md5 фикстуры `253c7ac5…` (F12 цел);
`./gfctl --help` → **0 вхождений «[этап 3]»**; `git status` — ровно ожидаемый
лес (M: gfctl, lib/commands.sh, lib/profiles.sh, tests/run_checks.sh; ?:
lib/agentcheck.sh, tpl/python/agent_check.py, tpl/python/watch_tui.py,
EXP-007-agentcheck.sh, dev-report.md, test-report.md); brief/task закоммичены
в 11dbe20. Независимое воспроизведение ручной проверки tester'а (faux-bin +
реальный диспетчер, curl reuse=none): `FAIL: disk-restore не сработал
(reuse=none)` → `AGENT-CHECK: PASS=3 WARN=1 FAIL=1`, **rc 1**, state-файл
удалён — совпадает с test-report дословно.

## Against DoD

| DoD-пункт (brief) | verdict | доказательство |
|---|---|---|
| 1. agent-check: 4 проверки; референсы из констант profiles; WARN >25%; rc 0 all-PASS / 0 при WARN / 1 при FAIL | **met** | `lib/agentcheck.sh`: cmp_ref — чистая функция (только stdout; float через awk; `measured ≤ ref×1.25` → PASS, иначе WARN+hint; ref='' → WARN «референс не снят (EXP-007)»); cmd_agentcheck — stage1 (сессия 15 ходов + лестница 5k/25k/100k + docq + restore-turn1) → cmp_ref по CHECK-строкам → container_up → wait_health 180 → stage2 → cmp_ref restore + reuse-вердикт; сводка `AGENT-CHECK: PASS=N WARN=M FAIL=K`, `f>0 → exit 1`, иначе rc 0 (WARN не считается отказом). Референсы `lib/profiles.sh:38-40` (23.8/1.7/0.81 — по brief/SPEC §5; flash-multi/27b-multi/docq unset → WARN). Батарея §33×9/§34×10/§34a×3; мой прогон 289/0; WARN=1 → rc 0 ассертован в §34; reuse=none → rc 1 воспроизведён мной независимо |
| 2. cache: сводка из логов; --verify ловит tmpfs (WARN) + контрольный follow-up | **met** | `parse_configured` (чистая, ПОСЛЕДНЯЯ `event=configured`, `\b`-граница — capacity не ловит disk_capacity; нет строки = норма rc 0); `cmd_cache` rc 0 всегда: du -sb, configured в GiB, skipped/evicted count-only (форматы в факт-базе нет — OQ-4), /metrics `llamacpp:prompt_tokens_cached_total` best-effort «?»; `cache_verify`: follow-up reuse live\|disk → PASS, none → **die rc 1 ДО рестарта** (§36 ассертит: `podman rm` не вызывался); tmpfs через `fs_type` (stat -f -c %T, шов батареи) → WARN, ext4 → негатив-ассерт. §35×8/§36×6+2 |
| 3. watch: TTY/не-TTY; q — выход; мёртвый сервер без спама | **met** (TUI-клавиши живьём — корректный BLOCKED-EXTERNAL, EXP-007) | `cmd_watch` — только грамматика `--interval N\|=N` (isint ≥1, дефолт 2) → exec python (env GFCTL_WATCH_PORT/INTERVAL/CONTAINER, паттерн hfctl); `watch_tui.py`: ветка по `sys.stdout.isatty()`+TERM, клавиши q/Q/+/(=)/-/(_)/p (handle_key), raw `llamacpp:*` отсортированные (rows_speed — имена НЕ выдуманы; grep predict_per_second по lib/tpl/tests — 0 вхождений), мёртвый сервер — ровно одна строка «недоступен» на тик (collect ловит Exception → None, без traceback; §37: TICKS=3 → ровно 3 строки, /metrics-счётчик = тикам). stdlib-only (импорты curses/glob/json/locale/os/re/shutil/signal/subprocess/sys/tempfile/threading/time/collections) |
| 4. Заглушки сняты РОВНО у agent-check/cache/watch; usage без «[этап 3]»; internal checks зелёные | **met** | diff `gfctl`: die-ветка `watch|cache|agent-check` заменена на три cmd_*; usage-строки трёх команд переписаны, остальные не тронуты (мой grep: 0×«[этап 3]»); батарея 233→289, §2-замена секции заглушек — по п.0-прецеденту, разрешено brief'ом дословно («осознанные замены секции заглушек — по п.0-прецеденту»); минус-строки диффа tests — только шапка faux-curl + §2 (12 строк, проверено мной) |
| 5. Регресс 1.1+1.2+2.1 цел | **met** | полный прогон 289/0 ×2 у меня, ×3 у tester'а; дифф старых секций по содержимому пуст (единственные минус-строки — разрешённая §2 и faux-curl-шапка); профильная таблица fields 1–9 не тронута (diff profiles.sh — чисто аддитивный, проверено); пины весов/модели не в diff; md5 фикстуры цел; WARN probe_context (commands.sh) не тронут — правильно, бэклог 2.1, не скоуп 3.1. Число «225» в brief устарело (после 2.1-F4 база была 233 — F23); суть пункта («регресс цел») доказана |
| 6. EXP-007 заготовка в очереди, не исполняется | **met** | `.dev/external/EXP-007-agentcheck.sh`: заголовок GOAL/PREREQ/RUN/PASS-критерии полный; **bootstrap-first** (install.sh — первый шаг remote-части, урок F21); хосты/ключи только через env GF_ACC_HOST/USER/KEY/FLAVOR с `:?`-гейтами; result-файла нет (не исполнялся — D6); `bash -n` OK; PASS-критерии покрывают PLAN-DoD этапа 3 (4 пункта agent-check, evo против 23.8/1.7/0.81, cache --verify + fs_type, сбор llamacpp:* и skipped/evict-образцов, TIMINGS_OK); `gfctl off` в конце (дорога hfctl on) |

Спецификация (SPEC §3/§5/§7/§8): протокол §7 (4 проверки, конверт greedy+reasoning off,
±25% → WARN, подсказка причины у follow-up/restore) — соблюден; референсы §5 —
как в SPEC (провенанс — см. Questions п.3); watch §8 — /metrics `llamacpp:*` +
host /proc//sys + podman logs (draft-приём в хвосте логов), TUI-каркас hfctl
переиспользован (§8 «переиспользуем 1:1»). Отклонение по «Скорости» SPEC §3 —
см. Questions п.2 (не блокер).

## Blocking

Нет.

## Non-critical notes (backlog)

1. **Триаж tester'а «reuse=none через реальный диспетчер — кандидат на
   ассерт» → BACKLOG, не blocking.** Ветка reuse=none в agent-check — 4
   строки, форма 1:1 с ассертованной в §36 (cache --verify: none → rc 1 +
   podman rm не вызывался); парсинг CHECK-строки общий. Поведение
   независимо воспроизведено мной через реальный диспетчер (rc 1,
   FAIL=1) — доказано сейчас, ассерт в §34 добавить при следующем
   касании батареи (как и предлагает tester).
2. `profiles.sh:36` атрибутирует все три числа «AGENT-CONFIGS п.3» — п.3
   буквально содержит 23.8 с (сессия, верно), но follow-up там
   «prompt_ms ~135–152» (мс, не turn2 wall) и restore «0.35 с @4.5k», а не
   1.7/0.81. Числа взяты из brief/SPEC §5 дословно — дефект не 3.1.
   Поправить комментарий при заполнении ref_* после EXP-007.
3. faux `stat` passthrough требует реальный stat в /usr/bin|/bin —
   задокументировано в коде, GNU-машины удовлетворяют. Приемлемо.
4. Худший бюджет agent-check (25 × -m 1200 c) — осознанный дизайн-лимит
   диагностической команды, прогресс печатается по ходам. Ок.

## Questions to the spec

1. **curl-vs-urllib: «Test strategy опертивна» — отклонение принято.**
   Сверено по task.md дословно: Test strategy §A требует «faux curl с
   timings+component_cache … ровно 25 chat-POST» (счёт POST возможен
   только через curl-шов), хвост Test strategy предписывает
   `GFCTL_FAUX_CURL_TIMINGS` + «счётчик тот же GFCTL_FAUX_CNT.curl», Risks
   формулирует лимит curl-флагом «-m 1200». Design §3 «curl-независимый
   python urllib» — внутреннее противоречие task.md (артефакт, не спека:
   SPEC транспорт не mandates). Реализация (subprocess-curl из PATH,
   список argv — ROUTE_MODEL с пробелами одним значением, тело через
   stdin/--data-binary, конверт окон байт-в-байт) соответствует
   опертивной секции и конвенциям AGENTS.md (stdlib-only соблюден:
   subprocess — stdlib). Задокументировано в dev-report Known
   limitations — правок не требуется.
2. **SPEC §3 watch: «Скорость (predict_per_second последнего запроса)»** —
   ключ в факт-базе gufo НЕ подтверждён (подтверждён только
   `llamacpp:prompt_tokens_cached_total`, FX-W5); реализация печатает
   сырые `llamacpp:*` без выдуманных имён (task.md OQ-2, dev-report).
   Рекомендация: одна строка правки SPEC §3 после EXP-007 (подписи по
   снятой факт-базе). До окна расхождение — в консервативную сторону и
   задокументировано, не блокер.
3. **Провенанс референсов SPEC §5 (27b-single: ≤1.7 с / 0.81 с @27k)** —
   в факт-базе gufo-27B таких чисел нет: EXP-IX (27B IQ4_XS, evo) даёт
   сессию 23.8 с и follow-up prompt_ms ~285 мс; 1.70 с (follow-up @25k) и
   0.81 с (restore @27k) — это окно CX на flash-next Q4_K_XL (FAEX,
   BENCH.md), AGENT-CONFIGS п.3 вообще даёт restore 0.35 с @4.5k.
   SPEC §5 (источник brief/task/impl) смешал окна/модели. Не блокер для
   3.1 (dev реализовал брифы числа 1:1; cmp_ref при расхождении живого
   замера даст WARN + задокументированный факт, FAIL-а не будет), но
   после EXP-007 (перепроверка evo против 23.8/1.7/0.81 живьём) провенанс
   стоит зафиксировать: заполненные ref_* — уже от канона 2×262144 и
   реального evo, SPEC §5 обновить тем же дельта-изменением.
