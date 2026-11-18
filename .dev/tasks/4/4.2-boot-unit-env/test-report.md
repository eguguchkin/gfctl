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
