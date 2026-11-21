# Test report: 4.2-boot-unit-env — юниты несли env диспетчера (defect EXP-009)

Verdict: **PASS**
Round: 1. Дата: 2026-11-18. Машины не тронуты (весь прогон — faux-харнесс батареи). Коммитов нет.

## Internal checks

| DoD | чек | результат |
|---|---|---|
| 1. Батарея, rc=0, счётчик 361 | `bash tests/run_checks.sh` на текущем дереве | ✅ rc=0, `ИТОГО: PASS=361 FAIL=0`, FAIL-строк нет; PASS-строк 361 |
| 1a. Целостность счётчика (358+1+2) | тот же прогон на HEAD-копии (git stash+checkout HEAD в /tmp-копии) | ✅ базлайн rc=0, `ИТОГО: PASS=358 FAIL=0` → 361 = 358 + 1 (мой §17, строка `PASS: юниты: Environment=GFCTL_DIR/GFCTL_MODELS = реальные пути стека (defect EXP-009)`, log:165) + 2 (§44-гвард слушателя + §44-smoke от 4.3) |
| 2. Ассерт §17 гоняет рендер, не статику | чтение тест-кода + харнесса: §17 (tests/run_checks.sh:670–678) ассертит `grep -Fqx` по `$ud="$TMP/home/.config/systemd/user"` — файлы созданы живым `cmd_install` (faux-bin, §17:648) → `install_units` → `render_tpl` c `TPL_DIR="$ROOT/tpl"` (харнесс gf():212–226: `UNIT_DIR="$HOME/.config/systemd/user"`, `STACK_DIR="$TMP/stack"`); пути в ассерте — харнессные `$TMP/stack{,/models}`, не литералы tpl | ✅ рендер живой; 4 grep -Fqx (обе строки в обоих юнитах) — точные совпадения строк |
| 2a. «Падает как надо» — ассерт | мутация 1 (копия репо, `sed -i '/^Environment=GFCTL_DIR=__GFCTL_DIR__$/d' tpl/systemd/gfctl-serve.service.tpl`) → полный прогон батареи | ✅ rc=1, ровно 1 FAIL: `юниты: Environment= не отрендерен реальными путями (defect EXP-009)`, ИТОГО 360/1 — ассерт точечный, шума нет |
| 2b. «Падает как надо» — die-гейт | мутация 2 (копия репо, из render-вызова serve удалена пара `GFCTL_DIR=...` → в юните остаётся `__GFCTL_DIR__`) | ✅ rc=1: `FATAL: нераскрытые плейсхолдеры в шаблоне …` → `FAIL: install happy-path (rc=1)` — молчаливый недорендер невозможен |
| 3. Шаблоны + render_tpl | tpl/systemd/gfctl-serve.service.tpl:14–15 и gfctl-watchdog.service.tpl:11–12 — `Environment=GFCTL_DIR=__GFCTL_DIR__` / `Environment=GFCTL_MODELS=__GFCTL_MODELS__`; render_tpl определён в lib/units.sh:29–41 (НЕ stack_files.sh — hfctl-имя, верно отражено в dev-report): подстановка `${tpl//__NAME__/value}`, гейт `grep -qE '__[A-Z0-9_]+__'` → die (units.sh:37–38); порядок пар — убывание длины (GFCTL_MODELS→PODMAN_BIN→GFCTL_DIR/STACK_DIR/CONTAINER); render-значения = разрешённые глобалы диспетчера (`STACK_DIR`, `MODELS_BASE` с учётом `--models-dir`) | ✅ |
| 4. Констрейнты дельты | `git status --porcelain` + `git diff HEAD`: изменены только файлы подэтапа (2 tpl, lib/units.sh, tests §17) + чужие 4.3 (models.sh, health.sh, gguf_type_check.py, SPEC.md, tests §44/§45 — хунки с §17 не пересекаются, проверено по диффу) + untracked task-папки; diff units.sh = только render-пары и док-комментарии; autostart.sh/commands.sh/install.sh не тронуты (`gfctl on` получает новый рендер через autostart_on → install_units); ssh/podman-наружу в дельте нет | ✅ |
| 4a. Внутренние чеки AGENTS.md | `bash -n gfctl lib/*.sh` OK; `python3 -m py_compile tpl/python/*.py` OK; `./gfctl` → usage, rc=1; `GFCTL_PORT=59999 ./gfctl status --json` → rc=0, валидный JSON `"health":"не запущен"` (корректный отказ, не краш) | ✅ |

## Failures (FAIL)

Нет.

## External experiments

| EXP-id | DoD | статус |
|---|---|---|
| EXP-009-reboot (окно 2026-11-18 вечера) | D6 (живой ребут-приём) | **не считается пройденным для этой дельты**: результат PASS получен с контингент-правкой Environment= руками на машине, т.е. ДО переноса в рендер; .result.txt зафиксирован |
| ребут-хвост дельты (следующее EXP-009-подобное окно acc-инсталляции) | D6 | **создан/описан, ответа нет** — пометка в dev-report подтверждена (§«Не проверено внутри (BLOCKED-EXTERNAL, DoD D6)»): критерии приёма = `systemctl --user show gfctl-serve -p Environment` показывает GFCTL_DIR/GFCTL_MODELS с реальными путями acc-инсталляции + journalctl без цикла statfs-отказов; исполняется оркестратором на следующем reboot-окне по GO пользователя. D6 — вне скоупа этого подэтапа, поэтому вердикт не BLOCKED-EXTERNAL |

## Regression

- Полная батарея tests/run_checks.sh — зелёная (361/0), каждый раунд.
- Мутационные прогоны (2 копии, /tmp) и базлайн-прогон HEAD-копии — артефакты удалены после проверки, дерево репо и машины не тронуты.

## Notes (non-blocking, ревьюеру)

1. **Косметический дефект die-сообщения render_tpl (pre-existing, НЕ этой дельты)**: units.sh:30 делает `shift 2`, поэтому в units.sh:38 `die "… в шаблоне $1"` печатает ПЕРВУЮ пару (`GFCTL_MODELS=/tmp/…`), а не путь tpl — см. вывод мутации 2. Гейт работает (rc=1, FATAL громкий), но «action recipe» ослаблена: не назван файл шаблона. Наблюдаемо на HEAD (render_tpl телом не менялся). Кандидат в 4.3 minor-polish.
2. SPEC §2 описывает юниты без уровня env (ExecStart/KillMode) — противоречия с дельтой нет, правка спеки не требовалась; если ревьюер сочтёт нужным зафиксировать «юнит несёт env диспетчера» — это одна строка в §2, вне моего скоупа.

## fix-r2 (2026-11-19): rm внутри каждой попытки container_up

Verdict: **PASS**

### Internal checks

| DoD | чек | результат |
|---|---|---|
| Батарея ×2, rc=0, 362/0 | `bash tests/run_checks.sh` ×2 на рабочем дереве | ✅ rc=0 оба: `ИТОГО: PASS=362 FAIL=0` (×2); ассерт §21 зелёный: `PASS: ретрай: каждая попытка начинается с rm (rm→run→rm→run — чистый слейт)` (b1.log:218); FAIL-строк нет |
| Целостность счётчика | базлайн на HEAD-копии (git stash+checkout) | ✅ HEAD 38bf32b: rc=0, `PASS=361 FAIL=0` → 362 = 361 + 1 (новый ассерт §21). (dev-report называет входной HEAD 9f796e1; текущий HEAD сдвинулся оркестратором, арифметика на нём сходится) |
| Ассерт §21 ловит «дубль rm» | мутация B (копия репо: пре-луп `podman rm -f` возвращён перед циклом) | ✅ rc=1, ровно 1 FAIL: `ретрай rm-в-цикле: последовательность 'rm rm run rm run '` — полный прогон батареи |
| Ассерт §21 ловит «нет rm в цикле» | мутация A (копия репо: rm-строка из цикла удалена) | ✅ ассерт ловит: в копии с нейтрализованным §17-grep — `FAIL: ретрай rm-в-цикле: последовательность 'run run '` (полный прогон, 358/4). ⚠️ на нетронутой копии батарея при этой мутации умирает РАНЬШЕ §21 (см. Notes 1) — rc=1 и без ИТОГО |
| bash -n; констрейнты | `bash -n lib/serve.sh tests/run_checks.sh`; `git diff HEAD` | ✅ bash-n OK; diff = lib/serve.sh (2 хунка: rm перенесён в цикл, коммент-контракт обновлён; пре-луп rm удалён) + tests/run_checks.sh (ровно +6 строк §21) + append dev-report (артефакт); чужих файлов нет; реальные podman/ssh-вызовы в дельте отсутствуют; машины не тронуты |

### External experiments

| EXP-id | DoD | статус |
|---|---|---|
| Живой рестарт-приём (use recreate / agent-check рестарт-restore на rootless podman) | fix-r2 D-хвост | **создан/описан, ответа нет** — пометка в dev-report подтверждена (§«Не проверено внутри (BLOCKED-EXTERNAL)»): рестарт-цикл agent-check без контингента-руками, journal/podman events без «already in use», recreate до healthy штатно; окно оркестратора (evo/FAEX), не влияет на вердикт подэтапа |

### Regression

- Полная батарея ×2 — зелёная (362/0); базлайн HEAD — 361/0; соседние rm-ассерты (§17 порядок, «die до рестарта» `grep -c rm = 0`) зелёные в обоих прогонах.
- Мутационные копии в /tmp удалены; дерево репо и машины не тронуты; коммитов нет.

### Notes (non-blocking, ревьюеру)

1. **Латентная хрупкость батареи (pre-existing, вскрыта мутацией A)**: §17 `i_rm=$(grep -n '^podman rm' "$FAUXLOG" | …)` под `set -o pipefail` молча убивает скрипт (rc=1, без ИТОГО), если в faux-логе нет ни одной строки `podman rm` — т.е. ровно в регрессии «rm исчез из container_up» батарея обрывается до §21 и специфичный сигнал ассерта теряется (остаётся только rc=1). Аналогично устроены «порядок warn/rm/POST» и «порядок verify». Лечение — `|| true` в этих подстановках (в нейтрализованной копии все 4 порядка-ассерта честно FAIL'ят: `rm=` пустой). Кандидат в 4.3 minor-polish.
2. Удаление пре-луп rm сменило семантику die-пути (bad-profile больше не сносит контейнер до die) — dev-report обосновывает (все живые вызывающие передают канон-профиль; die раньше всякого podman). ПротивSPEC §8 («recreate = rm+run») не бьёт: recreate-путь — успешная ветка, rm по-прежнему перед каждым run.

## fix-r2 теста (2026-11-21): enable при install_units (инцидент evo, EXP-009-хвост)

Verdict: **PASS**

Дерево: HEAD `7325c0a` + незакоммиченный fix-r2 (`lib/units.sh`, `lib/autostart.sh`, `tests/run_checks.sh`, append dev-report). Машины не тронуты (весь прогон — faux-харнесс батареи + смок диспетчера без podman). Коммитов нет. Проверено до попытки `enable watchdog.service` живьём — верификация семантики реального systemctl выполнена по исходникам systemd v252/v256 (см. Notes 1).

### Internal checks

| DoD | чек | результат |
|---|---|---|
| 1. Батарея, rc=0, счётчик 367 | полный прогон `bash tests/run_checks.sh` на рабочем дереве | ✅ rc=0 за 19 с: `ИТОГО: PASS=367 FAIL=0`; PASS-строк 367, FAIL-строк 0; все 5 §18-ассертов fix-r2 зелёные (log:188–192) + §17-счётчик «юнит-файлов 3 (без дублей)» (log:177) |
| 1a. Целостность счётчика (363+4) | тот же прогон на HEAD-копии (git clone → 7325c0a) | ✅ базлайн rc=0, `PASS=363 FAIL=0`; diff PASS-строк HEAD↔дерево = ровно §18 (−1 ассерт «use: автозапуск не трогает», +5 новых) + 2 косметических строки без счёта (§17 rename, §44 случайный порт) → 363+4=367, посторонних дельт нет |
| 2. Мутация §18 «убрать блок daemon-reload/enable» (копия, не дерево) | копия mutA: sed удалены строки `daemon-reload` + обе `enable` из install_units (start остался), bash -n OK → полный прогон | ✅ rc=1, `ИТОГО: PASS=364 FAIL=3` — ровно 3 §18-FAIL: `use: daemon-reload не вызван`, `use: enable serve+watchdog.service не вызван`, `wants-симлинки после use отсутствуют`; таймер-ассерт зелёный (start не удалялся) — ассерты точечные, шума нет |
| 2b. Мутация «только enable-строки» (копия) | копия mutB: удалены только 2 enable-строки → полный прогон | ✅ rc=1, `ИТОГО: PASS=365 FAIL=2` — ровно `enable serve+watchdog.service` + `wants-симлинки`; daemon-reload зелёный. Мутации различимы → §18 не «резиновый». «Вернуть»: рабочее дерево сверено md5 до/после — не тронуто; копии удалены |
| 3. bash -n изменённых lib-файлов | `bash -n gfctl lib/*.sh` (+ py_compile tpl/python/*.py) | ✅ OK |
| 4. Идемпотентность «после use = после cmd_on» | сверка кода (units.sh:88–91 ↔ autostart.sh:34–42) + ассерты батареи | ✅ install_units: reload → enable serve+watchdog.service → enable timer → start таймера; autostart_on = install_units + СВОЙ reload/enable(serve+timer)/start (дублирование идемпотентно, задокументировано в докстринге autostart.sh:25–28) + rm маркера + linger. Итог: юнит-состояние после use = после on минус linger — задокументированное отличие. Перо батареи: §18 (5 ассертов: reload/enable/симлинки/таймер/linger-нетронут), install «автозапуск ВКЛ»+enable-linger (log:695/724), `gfctl on → rc 0` (:905), off/uninstall linger off (:902/:988); повтор install → rc 0, юнит-файлов 3 (идемпотентность нового блока, log:745–748) |
| 5. Смок диспетчера (без podman) | `./gfctl` / `./gfctl --help` / `GFCTL_PORT=59999 ./gfctl status --json` | ✅ без аргументов → usage, rc=1 (usage и есть action recipe); --help → rc=0; мёртвый порт → rc=0, валидный JSON `"health":"не запущен"` — корректный отказ, не краш |

### Failures (FAIL)

Нет.

### External experiments

| EXP-id | DoD | статус |
|---|---|---|
| Живой ребут-приём fix-r2 (самоподъём после enable; evo/FAEX — следующий ребут после пуша) | закрытие EXP-009-хвоста | **создан/описан, ответа нет** (живой приём вне подэтапа, окно оркестратора — вердикту не мешает, как в r1/r2). Критерии приёма дополнены Notes 1: `is-enabled` → serve=enabled, timer=enabled, **watchdog.service=static (симлинка не будет — это норма)**; после ребута gfctl-serve active без ручных команд |

### Regression

- Полная батарея = регресс всех закрытых подэтапов — зелёная 367/0 (§17/§18 юниты+env, §21 rm-ретрай прошлого fix-r2, §24/§41 uninstall v2, §25 status+оверрайд, §44/§45 от 4.3, agent-check, watchdog, boot).
- AGENTS-чеки все выполнены (bash -n, py_compile, usage rc=1, status --json refusal).
- Мутационные копии, HEAD-клон и логи удалены (/tmp чист); рабочее дерево после мутаций — md5-сверка OK; `.data/` в корне репо — артефакт сессии разработчика 2026-11-20 22:25 (пустой каркас), мной не создавался и не тронут; машины не тронуты; коммитов нет.

### Notes (non-blocking, ревьюеру)

1. **enable watchdog.service на живом systemd — безоперационный no-op (faux-слепое пятно, НЕ брейкер)**: tpl/systemd/gfctl-watchdog.service.tpl НЕ имеет секции [Install] (корректно — юнит запускается таймером, канон logrotate.service; [Install] есть в serve и timer). По исходникам systemd v252/v256 (`verb_enable` + `do_unit_file_enable` + `install_context_apply`): mixed-вызов `enable serve.service watchdog.service` на живой системе → rc=0, serve получает wants-симлинк, watchdog.service пропускается молча (0 правил симлинков; notice «no installation config» не печатается, т.к. carries_install_info=1 от serve; AUXILIARY_FAILED не срабатывает — файл юнита существует). Следствия: (а) die на живой машине невозможен — fix-r2 безопасен, цели инцидента достигаются парой serve+timer; (б) §18-ассерт «enable-симлинки в default.target.wants (все три)» зелёный в батарее, но живьём третий симлинк не возникнет никогда — faux enable не моделирует [Install]; лог-ассерты (вызов случился) живы и честны; (в) опасение dev-report о boot-гонке «enable'нутый watchdog.service при boot» — структурно беспочвенно (static-юнит при boot не стартует); (г) note dev-report про «висящий wants-симлинк watchdog.service» в off/uninstall — moot. Опция polish (не блокер): убрать watchdog.service из enable-вызова + из faux-ассерта, или оставить как есть + одна строка-комментарий в units.sh — решение за оркестратором; на живое поведение не влияет.
2. Оверрайд `GFCTL_FAUX_SYS_ENABLED` — единственный потребитель §25 (2 вызова status, log:1015/1018); остальные is-enabled идут по wants-артефакту честно — все зелёные в полном прогоне.
3. Системного systemctl в среде нет — живой отказ systemctl-вызовов не моделировался; по контракту units.sh (`@returns`: сбои mkdir/install/systemctl завершают процесс по set -e) отказ громкий с родным stderr — подтверждается контрактом, живое подтверждение уходит в EXP-окно ребута.
