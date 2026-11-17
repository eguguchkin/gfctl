# Review: 1.2 жизненный цикл — serve-юниты + install/use/on/off/uninstall + smoke/logs + watchdog/boot

Verdict: **APPROVED**
Round: 1

Ревьюер независимо перепрогнал и проверил: `bash tests/run_checks.sh` →
**PASS=180 FAIL=0, rc 0** (пересчёт секций по живому выводу — ниже);
`bash -n gfctl lib/*.sh` OK; `python3 -m py_compile tpl/python/*.py` OK;
md5 bench-фикстуры = `253c7ac50857fe6d0e10fb0d2c5e35c0` ✓ (не редактировалась);
заглушки этапов 2–3 живые: `watch|bench|cache|agent-check` → каждая rc 1
«команда 'X' — этап 2/3»; bare rc 1, `--help` rc 0, `status --json` на мёртвом
8198 — валидный JSON (json.tool). Выборочная сверка кода с фактами/спекой:
F9 (serve.sh:140–147 — набор флагов ровно как в F9, маунт каталога-сета
models:ro), F10 (serve.sh:131/135/150 — rm → пауза 3 с → до 3 попыток run
с паузой 5 с), F16 (autostart.sh:132 — маркер ПЕРВЫЙ statement _watchdog),
F11 (grep по lib/: `disable-linger` ровно два места — autostart.sh:109
cmd_off и commands.sh:558 cmd_uninstall; enable-linger — только autostart_on
autostart.sh:37), F15 (health.sh:166–169, дефолт 15 с), D3 (единственные
касания «соседа» — WARN-строки commands.sh:199/379; кода takeover/авто-
переключения нет — grep по gfctl/lib/). Решения OQ в коде: gpu-lock →
WARN+continue (commands.sh:377–380), `--no-probe` → WARN no-op
(commands.sh:441), `down` = `off` (gfctl:199 `off|down) cmd_off`),
load_failed-порог 20 с (health.sh:62, `GFCTL_LOADFAIL_AFTER:-20`). SPEC §2
пути (~/gufo, ~/.config/systemd/user, models/, cache/<профиль>, маркер,
logs, limits.d/99-gfctl-memlock.conf) — все на месте; SPEC §4 канон
(~/gufo/.env): write_canon = render env.tpl → .env.tmp + `mv -f` (атомарно,
die на нераскрытых `__X__`), чтение `grep '^KEY=' | tail -1 | cut -d= f2-`
устойчиво к повтору install/use (полная перезапись, накопления нет) и к
`=`/пробелам в значениях. Hygiene: grep по репо — IP/хосты/ключи только в
допустимых местах (loopback в коде; имена машин лишь в blackboard-доках
.dev/, не в коде и не в EXP); EXP-001/002/003 параметризованы
GF_ACC_HOST/USER/KEY, живых машин не содержат; STATE/history — записи только
оркестратора. Регресс 1.1: секции §3–11,13 зелёные и нетронуты (§3=1, §4=11,
§5=4, §6=31, §7=5, §8=5, §9=5, §10=1, §11=7, §13=4 — структура 1.1
сохранена); §2/§12 замещены ровно по п.0 Test strategy task.md (санкция
дизайна, не поломка).

## Against DoD

| # | item (brief) | met/partial/missing | proof |
|---|---|---|---|
| 1 | install/use/on/off/uninstall/logs/smoke/_watchdog реализованы; заглушки сняты РОВНО у них (watch/bench/cache/agent-check остаются) | **met** | роутер gfctl:195–204 (вкл. скрытые up/down/_boot); мой прогон: 4 заглушки этапов 2–3 → rc 1, остальные живые; каждая команда имеет батарею (§17 install, §18 use, §20 off/on/up/_watchdog/_boot, §22 logs, §23 smoke, §24 uninstall) |
| 2 | tpl/: serve-юнит (oneshot + RemainAfterExit), watchdog .service+.timer (1 мин), boot-юнит, env-шаблон — генерация с подстановкой | **met** | tpl-файлы прочитаны (oneshot/RemainAfterExit=yes/KillMode=process/TimeoutStartSec=900/Restart=on-failure; OnUnitActiveSec=1min); §16 render_tpl + die на чужом `__X__`; §17: 3 юнита с контент-грепами в $UNIT_DIR; env.tpl байт-в-байт (§14). Merge serve=boot — задокументированное решение task.md Design (SPEC §2 «gfctl-serve*», §8 «serve-unit + watchdog timer»); второй boot-юнит дрался бы за контейнер |
| 3 | Serve-строка ИЗ профильной таблицы (@DRAFT@/@MTP@ → /models/…, F9 ровно, порт D2/--port) | **met** | serve_args (serve.sh:34–54): поле 7 + подстановка токенов, неизвестный токен → die; §15 канон байт-в-байт; §17 podman run байт-в-байт канону Design с реальными $TMP-путями (мой пересмотр ассертов батареи); flash = первый шард 00001 + @MTP@ |
| 4 | Health-предикат: podman logs до `load_completed` (таймаут ~3 мин, прогресс-печатка), затем HTTP-проба | **met** | wait_load 180 с дефолт, шаг GFCTL_HEALTH_POLL, печать «жду загрузки… Ns», ранний выход на load_failed (порог 20 с); затем http_ready-поллинг до 30 с → строка роута; §19 (7 PASS: последняя load_completed побеждает, таймаут → хвост логов, /ready-отказ → rc 1) |
| 5 | Порядок фиксированный: recreate → health → smoke | **met** | cmd_install (commands.sh:401–403) и cmd_use (456–458): container_up → wait_health 180 → smoke; §17/§18: индексы faux-лога rm < run < logs < /ready < chat |
| 6 | `off` → вотчдог НЕ воскрешает (маркер раньше подъёма); `on` возвращает всё | **met** | cmd_watchdog: маркер — первая строка (autostart.sh:132), §20 «ноль podman-вызовов, rc 0» (мой пересмотр); off: touch РАНЬШЕ podman rm и systemctl disable (§20 порядок по логу), юниты удалены, linger off; on: enable serve+timer, маркер снят, юниты восстановлены, linger on, подъём; on без smoke (0 chat) |
| 7 | uninstall без флагов оставляет модели и образ | **met** | §24 (мой пересмотр): веса на месте, `podman rmi` ОТСУТСТВУЕТ в логе, дерево снесено кроме models; согласие обязательно (не-TTY → rc 1 и ничего не удалено); purge-флаги работают |
| 8 | Internal checks зелёные (батарея расширена секциями новых команд с PATH-заглушками) | **met** | мой прогон PASS=180 FAIL=0 rc 0; faux-bin 6 заглушек с построчным логом; тесты проверяют DoD-поведение (байт-в-байт строки, порядок вызовов, маркер-раньше-подъёма), не внутренности |
| 9 | Регресс 1.1 не сломан (все прежние ассерты проходят) | **met** | §3–11,13 зелёные и нетронуты (пересчитано по живому выводу); §2/§12 замещены осознанно по п.0 task.md (снятие заглушечной секции и живой формат человекостроки — санкционированное ОБНОВЛЕНИЕ батареи); старые контракты живы: JSON-схема мёртвого порта (route/autostart/version=null + gates + models), check-types RED-контракт, пины/суммы, install.sh |

BLOCKED-EXTERNAL не замаскирован: реальный podman/systemd/loginctl/curl-HF
честно вынесен в EXP-001/002/003 (созданы, не исполнялись, приёмка этапа 1
на evo с GO пользователя); dev-report «Not checked internally» перечисляет
ровно эти зоны. DoD 1.2 — локальные доказательства, все закрыты.

## Blocking

— нет. Ни DoD-неполноты, ни спека-мисматча, ни сломанного контракта 1.1, ни
дыр в секретах/hygiene, ни необработанных отказов на главных путях.

## Non-critical notes

Триаж 2 backlog-заметок tester'а (критерий блокирования: ломает DoD или
агентский контракт — ни одна не достигает) + собственные находки:

1. **EXP-003 «быстрый путь» не увидит веса EXP-002 (исправить ДО окна
   приёмки).** В REMOTE-сценарии экспортируется только `GFCTL_DIR`;
   `GFCTL_MODELS` не задан, а ветка `[ -f …gfctl-acc-models/27b/…] → use
   27b-single` зовёт `use` без `--models-dir`. ensure_weights будет смотреть
   в `$GFCTL_DIR/models/27b`, не найдёт там 15 GiB, и при экспортированном
   `GFCTL_YES=1` молча начнёт повторную скачку ~15 GiB в стек — «быстрый
   путь» превращается в полный (форма EXP формально останется PASS, окно
   потеряет часы + задвоение весов на диске). Фикс — одна строка:
   `export GFCTL_MODELS="$MODELS"` рядом с `GFCTL_DIR` (EXP-скрипт, зона
   оркестратора; на вердикт 1.2 не влияет — EXP в очереди, не исполнялся).
2. **Арифметика разбора секций в test-report неточна.** Таблица «§3–11,13:
   38 PASS» — фактически 74 (мой пересчёт живого прогона: 1+11+4+31+5+5+5+
   1+7+4); «95 старых» — фактически 96. Итог 180 верен, секции новы/стары
   как заявлено, зелёные — ошибка подсчёта в отчёте, не в тестах. Пополнять
   нечего (report append-only), достаточно этой фиксации.
3. **Backlog 1.1 note#3 не закрыт (снова).** §13 батареи по-прежнему `cmp`
   с /workspace/hfctl/tpl/bench/… (run_checks.sh:391) — на машине без hfctl
   ложный FAIL (ложный PASS невозможен). md5-контроль tester'ом сделан
   вручную. Замена на md5-assert осталась backlog (в 1.1 помечено «можно в
   1.2» — не сделано; не блокер: defect не маскируется).
4. **Backlog 1.1 note#4 не закрыт (снова).** §13 не герметична по $HOME
   (install.sh оставляет dangling-симлинк в реальном ~/.local/bin); tester
   артефакт почистил, мой прогон чист. Лечится подменой HOME секции.
5. **uninstall-слой 5 защищает только top-level базу весов.** Guard
   `find -mindepth 1 -maxdepth 1 ! -path "$MODELS_BASE"` сохраняет базу,
   если она ВНУТРИ стека ровно на первом уровне (дефолт) или вне стека;
   `--models-dir ~/gufo/x/models` (глубже уровня) снесётся вместе со стеком
   БЕЗ --purge-models. Угол (реалистичные конфигурации — дефолт и внешняя
   база, оба корректны; согласие ask стоит), но команда разрушающая —
   defense-in-depth уместен: case-guard `"$STACK_DIR"/*` → сносить
   top-level родителя, не базу. Backlog этапа 4 (uninstall-хардening).
6. **Семантика маркера при use/install --no-autostart после off.** `up`
   снимает маркер (cmd_up:58), `use` и `install --no-autostart` — нет:
   после явного off профиль сменили use'ом → контейнер поднят, но вотчдог
   глушен до `on`/`up`. Читается как «последняя явная воля — off», дизайн
   task.md этому не противоречит; поведение стоит либо задокументировать в
   usage/off-строке, либо синхронизировать с `up`. Backlog, решать при
   этапе 4 (хардening) или по факту EXP-003.
7. **`gfctl off`: daemon-reload и disable-linger без `|| true`** —
   санкционировано task.md Design (юниты к тому моменту сняты); на машине
   без юзер-сессии off оборвётся после слоя юнитов, linger останется on
   (безвредно: юнитов нет — подниматься нечему). Edge, не main-path.
8. **`logs 50 100`** — оба числа ints, второе молча побеждает (второй цикл
   разбора). Косметика валидации аргументов.
9. **env-shadowing `GFCTL_PORT` vs `install --port N`** — env побеждает,
   аргумент молча затенён; developer задокументировал + предложил WARN в
   out-of-scope. Согласовано во всех потребителях (всё через canon_port).
   Backlog, одна строка при удобном случае.
10. **JSON-экранирование `route.model`/`cache.dir`/`bind`** — backlog 1.1,
    остаётся (dev-controlled значения, кавычек не содержат).
11. **`gf`-harness дублирует глобалы диспетчера** (IMAGE/STACK_DIR/…) — при
    правке шапки gfctl синхронизировать вручную; комментарий в harness есть.
    Минор.

## Questions to the spec

1. **SPEC §2 словесность «systemd-user юниты `gfctl-serve*`»**: фактически
   ставятся три юнита — gfctl-serve.service, gfctl-watchdog.service,
   gfctl-watchdog.timer; отдельного boot-юнита нет (serve-юнит = boot,
   ExecStart=_boot — решение задокументировано в task.md Design и
   соответствует SPEC §8 «serve-unit + watchdog timer»). Стоит уточнить
   формулировку §2 (или оставить §8 единственным носителем модели) — иначе
   следующий читатель спеки будет искать несуществующий gfctl-boot.
2. **load_failed-порог 20 с — ещё не факт.** GFCTL_LOADFAIL_AFTER=20
   выбран из осторожности (не ловить ложный load_failed при старте podman),
   живых доказательств нет. EXP-003 при первом прогоне закроет это фактом —
   результат (ловит/не ловит, реальный ритм загрузки ~90 с) писать в
   FACTS.md, не в role-тексты.
3. **watchdog-семантика маркера при use после off** (note 6) — спека
   (§4 «off ставит маркер») молчит о снятии маркера неявными подъёмами.
   Одна строка в §4 или в описании `use` снимет вопрос перед этапом 4.
