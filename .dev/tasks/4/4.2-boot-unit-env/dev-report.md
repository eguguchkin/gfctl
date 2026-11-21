# Dev report: 4.2-boot-unit-env — serve-юнит не переносит GFCTL_DIR/GFCTL_MODELS

- Дата: 2026-11-18. Fix round: 1 (первый проход). Коммитов нет (коммит —
  оркестратор). Машины не трогались.
- Дефект: EXP-009 (history 2026-11-18 вечер) — после ребута FAEX gfctl-serve
  падал циклом (~12.5 мин activating): юнит ExecStart зовёт
  `bash $STACK_DIR/gfctl _boot`, но env юнита не содержит GFCTL_DIR/GFCTL_MODELS
  → диспетчер брал дефолты `$HOME/gufo` + `$STACK_DIR/models` → statfs
  несуществующего пути. Контингент-правка Environment= руками на машине
  закрыла; этот подэтап переносит её в рендер.

## Что было сделано

| файл | изменение |
|---|---|
| `tpl/systemd/gfctl-serve.service.tpl` | +2 строки в [Service]: `Environment=GFCTL_DIR=__GFCTL_DIR__`, `Environment=GFCTL_MODELS=__GFCTL_MODELS__` (+2-строчный комментарий «почему») |
| `tpl/systemd/gfctl-watchdog.service.tpl` | те же 2 строки Environment= (+комментарий) |
| `lib/units.sh` | `install_units`: оба render-вызова дополнены парами `GFCTL_DIR="$STACK_DIR"`, `GFCTL_MODELS="$MODELS_BASE"`; обновлены док-комментарии модуля и install_units |
| `tests/run_checks.sh` | §17 (install happy-path): 1 стаб-тест «после рендера юнит содержит Environment= обеих переменных с реальными путями» (grep -Fqx обеих строк в serve.service и watchdog.service) |

Уточнение к формулировке задачи: рендер в gfctl живёт НЕ в
`lib/stack_files.sh` (это hfctl-имя, упомянутое в задании «1:1 из hfctl») —
здесь это `lib/units.sh` (`render_tpl` + `install_units`). `lib/autostart.sh`
правок НЕ требует: `autostart_on` (и через неё `cmd_on`/`cmd_install`)
вызывает `install_units`, т.е. «autostart ставит serve-юнит + watchdog-таймер»
автоматически получает новый рендер. Порядок пар в render-вызовах — убывание
длины имён (контракт render_tpl «длинное раньше короткого»).

## Механика рендера

- Единственный писатель обоих юнит-файлов — `install_units` (grep по репо:
  tpl-файлы упоминаются только там). Таймер — статичный, плейсхолдеров не
  имеет, не менялся.
- Значения берутся из глобалов диспетчера в момент установки юнитов — те же,
  из которых диспетчер живёт прямо сейчас:
  - `GFCTL_DIR="$STACK_DIR"` — `STACK_DIR="${GFCTL_DIR:-$HOME/gufo}"` (gfctl:44),
    т.е. реальный install-путь (acc: `$HOME/gfctl-acc`);
  - `GFCTL_MODELS="$MODELS_BASE"` — `MODELS_BASE="${GFCTL_MODELS:-$STACK_DIR/models}"`
    (gfctl:45), с учётом оверрайда `install --models-dir` (commands.sh:420
    пишет прямо в MODELS_BASE). Берётся именно разрешённый глобал, а не сырое
    env — иначе `--models-dir`-инсталляции получили бы пустую переменную.
- Результат: после install/use/on юнит несёт env диспетчера; `_boot`/`_watchdog`
  при ребуте резолвят ровно тот же STACK_DIR/MODELS_BASE, что и при установке.
  Плейсхолдеры `__GFCTL_*__` больше нигде не используются; render_tpl умирает
  (die) на нераскрытых плейсхолдерах — молчаливый недорендер невозможен.
- systemd: `Environment=KEY=value` без кавычек — как существующий стиль юнитов
  (WorkingDirectory/ExecStart тоже без кавычек; допущение «пути без пробелов»
  уже заложено в tpl-канон и док-комментарий render_tpl «значение не
  экранируется (пути/числа)»).

## Сверка других точек с дефолтом `$HOME/gufo` (задание п.1, без правок)

| точка | вердикт |
|---|---|
| `install.sh:24` `DEST="${GFCTL_DIR:-$HOME/gufo}"` | СОГЛАСОВАН с диспетчером (gfctl:44): дерево раскладывается туда же, куда юнит теперь вшивает GFCTL_DIR. Конфликта с install-путём нет; правка не требовалась и не сделана |
| `lib/commands.sh:1146–1163` (uninstall) | жёстко зашитые приёмочные пути `~/gfctl-acc{,-src}`, `~/gfctl-acc-models` и echo-список «нетронутых» (`~/gufo-models` и пр.) — существующее поведение этапа 4.3/EXP-очистки, к дефекту юнит-Env отношения не имеет; вне скоупа, НЕ тронуто (наблюдение в backlog, если оркестратор сочтёт) |
| `lib/state.sh:2` заголовок «~/gufo/.env» | комментарий-архаизм (реальный путь `$STACK_DIR/.env`); на поведение не влияет, не тронуто |

## Как проверено внутри

- `bash -n gfctl lib/*.sh install.sh` — OK (install.sh — не менялся, для полноты).
- `python3 -m py_compile tpl/python/*.py` — OK.
- Батарея `bash tests/run_checks.sh`:
  - ДО правок (базлайн): `ИТОГО: PASS=358 FAIL=0`;
  - ПОСЛЕ: мой тест зелёный — `PASS: юниты: Environment=GFCTL_DIR/GFCTL_MODELS = реальные пути стека (defect EXP-009)`, сразу после моей правки `ИТОГО: PASS=359 FAIL=0`.
  - ВАЖНО (движущаяся цель): параллельный разработчик в это же время коммитит
    в рабочее дерево свои тесты в тот же run_checks.sh — на момент финального
    прогона счётчик дошёл до `PASS=361 FAIL=0`. Мой вклад строго +1 тест;
    FAIL=0 на всех прогонах. Окончательное «зелёное» число фиксирует тестер
    на нераспараллеленном дереве.
- Прямой контрольный рендер (faux-podman, субшелл, вне батареи):
  `install_units` при `STACK_DIR=/home/ai/gfctl-acc`,
  `MODELS_BASE=/home/ai/gfctl-acc-models` даёт в обоих юнитах
  `Environment=GFCTL_DIR=/home/ai/gfctl-acc` +
  `Environment=GFCTL_MODELS=/home/ai/gfctl-acc-models`; WorkingDirectory/
  ExecStart не изменились; нераскрытых `__X__` нет.
- `git diff` по моим файлам минимален (см. таблицу выше); в рабочем дереве
  также есть правки второго разработчика (`lib/models.sh`, `lib/health.sh`,
  `tpl/python/gguf_type_check.py`, §44 в tests/run_checks.sh) — НЕ мои, не
  тронуты; мой тест в §17 с их §44 не пересекается (разные hunk'и).

## Не проверено внутри (BLOCKED-EXTERNAL, DoD D6)

- Живой ребут-приём: что после реального ребута юзер-менеджер поднимает
  gfctl-serve с вшитым Environment= и gufo доходит до health без ручных команд
  (EXP-009-подобное окно). Подтверждать: следующий reboot-цикл acc-инсталляции
  — `systemctl --user show gfctl-serve -p Environment` должен показать обе
  переменные с реальными путями, journalctl — без цикла statfs-отказов.
- `systemd-analyze verify` отрендеренных юнитов в этой среде недоступен
  (нет systemd-user контекста/машины) — синтаксис Environment= каноничный,
  но живой парсинг systemd не проверялся.

## Ограничения / допущения

- Рендер вшивает значения МОМЕНТА установки юнитов: если стек переезжает на
  другой путь, нужен повтор `gfctl on`/`install` (уже стоявшие юниты
  перерендерятся с новыми значениями) — та же семантика, что у существующего
  `__STACK_DIR__`/`__PODMAN_BIN__`, нового риска не добавляет.
- Если пользователь запускает `gfctl on` без GFCTL_DIR в env при стеке вне
  `$HOME/gufo`, диспетчер сам резолвит дефолт — юнит вшьет дефолт (как и
  сегодня; лечение — env в юнит НЕ переносит запуск интерактивной сессии,
  вне скоупа).
- Пути с пробелами сломали бы и старые подстановки (ExecStart), и новые
  Environment= одинаково — допущение «пути без пробелов» канона tpl.

## Out-of-scope proposals

- `systemd-analyze verify` отрендеренных юнитов добавить шагом в батарею,
  когда в ocbox появится пригодный systemd (сейчас — только живьём на машине).
- Док-комментарий `lib/state.sh:2` «~/gufo/.env» → «$STACK_DIR/.env»
  (косметика, следующий doc-проход).
- Жёстко зашитые приёмочные пути в cmd_uninstall (commands.sh) — обсудить
  на 4.3 minor-polish.

## fix-r2: rm внутри попыток container_up (2026-11-19, append)

- Дата: 2026-11-19. Fix round: 2. HEAD 9f796e1 (дерево чисто на входе,
  параллельных работ нет). Коммитов нет, машины не тронуты.
- Дефект: evo-повтер EXP-009 (history 2026-11-19 ночь) — рестарт-restore
  упёрся «container name gufo already in use» ×3: `container_up` делал rm
  ОДИН раз ДО цикла, а попытки 2/3 били `podman run` в контейнер, чей
  rootless-teardown (loading-контейнер) ещё не завершился — teardown
  медленнее паузы 5 с. Контингент: `podman rm -f gufo` руками → пересоздание.
  Лечит класс: любая попытка run теперь начинается с чистого слейта.

### Что было сделано

| файл | изменение |
|---|---|
| `lib/serve.sh` | `container_up`: `podman rm -f "$CONTAINER" >/dev/null 2>&1 || true` перенесён ВНУТРЬ цикла попыток (первая строка каждой итерации, перед run); коммент-контракт обновлён («rm один раз до цикла» → «rm ВНУТРИ цикла, перед каждым run — единственный rm») |
| `tests/run_checks.sh` | §21 (recreate-ретрай): +1 мутационный ассерт — по faux-логу харнесса сверяется последовательность podman-вызовов сценария «run падает 1 раз»: `rm run rm run` (grep -E только строк `podman rm -f gufo`/`podman run -d --name gufo`, cut поля 2, tr в строку) |

**Выбор «убрать начальный rm»** (из двух разрешённых вариантов): оставленный
пре-луп rm давал дубль на первой попытке — фактическая лога-последовательность
`rm rm run rm run` (поймано на первом прогоне батареи: ассерт FAIL, см.
«проверено» ниже). Эталон DoD — `rm→run→rm→run` — достижим только без
пре-луп rm. Доводы: (а) единый контракт «каждая попытка = rm→run», без
сособого случая для попытки 1; (б) нулевая цена: `podman rm -f` отсутствующего
имени мгновенен и заглушен `|| true`. Обоснование удаления семантики на
die-пути: раньше bad-profile `container_up` успевал снести контейнер до die —
теперь die происходит БЕЗ побочного эффекта на контейнер (все живые вызывающие
передают канон-профиль из cur_profile; невалидный id = программная ошибка,
пойманная profile_field/die раньше всякого podman).

### Как проверено внутри

- `bash -n gfctl lib/*.sh install.sh` — OK; `python3 -m py_compile
  tpl/python/*.py` — OK.
- Батарея ДО (HEAD 9f796e1): `ИТОГО: PASS=361 FAIL=0`.
  Промежуточный факт: после первого варианта правки (пре-луп rm ОСТАВЛЕН +
  rm в цикле) ассерт честно поймал дубль — `FAIL: … 'rm rm run rm run '`;
  после удаления пре-луп rm — `PASS: ретрай: каждая попытка начинается с rm
  (rm→run→rm→run — чистый слейт)`. Мутационное свойство подтверждено
  дважды: без rm-в-цикле последовательность была бы `rm run run`, с дублем —
  `rm rm run rm run`; ассерт различает оба искажения.
- Батарея ПОСЛЕ: `ИТОГО: PASS=362 FAIL=0` (361→362, ровно +1 ассерт).
- Соседние ассерты на rm в логе (первый-rm-порядок в §17/agent-check,
  `grep -c '^podman rm' = 0` в ветках «die до рестарта»/«install на healthy»)
  — не задеты: первый rm в логе по-прежнему раньше первого run, в сценариях
  без вызова container_up счётчик остался 0.

### Не проверено внутри (BLOCKED-EXTERNAL)

- Живой рестарт-приём: что `use recreate`/agent-check рестарт-restore на
  реальном rootless podman больше не ловит «already in use» при медленном
  teardown loading-контейнера (окно оркестратора; evo/FAEX). Подтверждение:
  рестарт-цикл agent-check без контингента-руками, journal/podman events без
  «already in use», recreate до healthy штатно.

### Ограничения / допущения

- rm перед КАЖДОЙ попыткой сносит и УСПЕШНО созданный контейнер предыдущей
  попытки только при переходе к следующей (успех = return 0 внутри if —
  rm следующей попытки не выполняется); поведение recreate (rm+run, SPEC §8)
  не меняется.
- Паузы (GFCTL_RECREATE_PAUSE_S=3 до цикла, 5 с между попытками) сохранены —
  F10 про медленное освобождение порта остаётся в силе; rm в цикле лечит
  именно «имя занято», не «порт занят».

### Out-of-scope proposals

- Диагностический хвост при исчерпании попыток (`podman logs --tail 30` после
  цикла) теперь показывает только контейнер ПОСЛЕДНЕЙ неудачной попытки: rm
  следующей попытки сносит логи предыдущих (faux-харнесс этого не моделирует —
  у него run не создаёт контейнер). Если живой рестарт покажет, что
  диагностик по ранним попыткам нужен — копить хвосты логов до rm следующей
  попытки (бэклог, окно покажет).


---

## fix-r2: enable при install_units (2026-11-20, подэтап 4.4-хвост / инцидент evo EXP-009-хвост)

- База: HEAD `7325c0a` (4.4-layout APPROVED), батарея 363/0 до правки.
- Статус: **developed** (не коммитил; машины не трогал).
- Дифф: `lib/units.sh` (+18/−5), `lib/autostart.sh` (только докстринг),
  `tests/run_checks.sh`; полный прогон **367 PASS / 0 FAIL ×2**.

### Инцидент и причина

Живой evo (EXP-009-хвост): после перезагрузки gfctl-сервер не поднялся —
юниты disabled. Причина: решение 4.4 «юниты при первом use» реализовано
неполно — `install_units` рендерил и раскладывал юнит-файлы в
`~/.config/systemd/user/`, но не делал `daemon-reload`/`enable` → нет
симлинков в `default.target.wants`, после ребута поднимать нечему.
Контингент на машине: `systemctl --user enable --now gfctl-serve.service`
(поднято вручную; FAEX сейчас healthy на ручном enable — живой ребут-приём
вне подэтапа).

### Правка (lib/units.sh, конец install_units)

```bash
systemctl --user daemon-reload
systemctl --user enable "$UNIT_NAME-serve.service" "$UNIT_NAME-watchdog.service"
systemctl --user enable "$UNIT_NAME-watchdog.timer"
systemctl --user start "$UNIT_NAME-watchdog.timer"
```

Сверка с `autostart_on` (цель «после use состояние юнитов = после cmd_on»):
- enable serve + watchdog.service + watchdog.timer, daemon-reload — теперь
  в `install_units`, т.е. и у `use`, и у `install`, и у `on` (идемпотентно);
- serve-юнит НЕ стартуется из install_units (oneshot: recreate в use/install
  уже поднял контейнер; старт юнита = второй podman run) — по условию задачи;
- watchdog-таймер стартуется (страж падений активен сразу после use — как
  после on);
- **linger — единственное отличие от cmd_on**: остаётся в autostart_on
  (on/install) — sudo из install_units не добавляли (исключение инварианта
  4.4, таблица в 4.4-layout-python-decision.md);
- on/off/uninstall поведение НЕ менялось: autostart_on сохраняет свои
  reload/enable/start (теперь частичное дублирование install_units —
  вызовы идемпотентны; в докстринге отмечено), cmd_off/cmd_uninstall без
  правок.

### Батарея (363 → 367, ×2 прогона)

- faux systemctl умеет enable/disable как РЕАЛЬНЫЕ артефакты: создаёт/снимает
  симлинки `$HOME/.config/systemd/user/default.target.wants/<unit>`;
  `is-enabled` теперь честный предикат по wants-симлинку (оверрайд
  `GFCTL_FAUX_SYS_ENABLED=yes|no` сохранён — им сценарится §25, где юниты
  ещё не расставлены после §24-uninstall). В `gf`-харнессе HOME/USER
  экспортированы (faux пишет под HOME).
- §18 (юниты при use): фикс-r1-очистка расширена (`rm -rf default.target.wants`),
  старый ассерт «use не зовёт systemctl» заменён контрактом fix-r2 (5
  ассертов): daemon-reload вызван; enable serve+watchdog.service вызван;
  все три wants-симлинка существуют (артефакт, не только лог); таймер
  стартован; linger НЕ тронут. +2 ассерта на use-юниты из 4.4 остались.
- §17: подсчёт «юнит-файлов по-прежнему 3» переведён на `find -maxdepth 1
  -type f` (в `$ud` появилась `default.target.wants` — ls-счётчик давал 4).

### Мутации (проверено на копиях репо)

| мутация | результат |
|---|---|
| удалён блок reload+enable×2 из install_units (остался start) | §18: 3 FAIL (daemon-reload, enable, wants-симлинки) → 364/3 |
| удалены ТОЛЬКО enable-строки (reload остался) | §18: 2 FAIL (enable, wants-симлинки) → 365/2 |

Чистое дерево: `bash -n` зелёный, **367/0 ×2**.

### Не проверено живьём

- Ребут-приём (самоподъём после enable) — окно EXP-009-хвоста на машине;
  FAEX сейчас healthy на ручном `enable --now` — до окна ребутить нельзя.
- Поведение при boot-гонке serve `_boot` ↔ немедленный `_watchdog` от
  enable'нутого watchdog.service (оба при старте юзер-менеджера):
  container_up с rm-в-цикле делает гонку безопасной по построению, но
  живого наблюдения нет — зафиксировать факт в окне.

### Out-of-scope proposals

- `off`/`uninstall` снимают enable только у serve+timer (не watchdog.service):
  на батарее это невидимо (faux disable точечный), в живой системе остаётся
  висящий wants-симлинк на удалённый файл — безвреден (юнит-файла нет),
  но для гигиены можно добавить watchdog.service в disable-список
  cmd_off/cmd_uninstall в окне миграции (сейчас не трогали по ограничению
  «не менять off/uninstall поведение»).

### fix-r2 round 3 (2026-11-21): 2 механических пункта review CHANGES_REQUESTED

Применяны ровно пункты review.md («fix-r2 review», Round 3), поведение не менялось.

1. **Спека (Blocking 1)**: `.dev/SPEC.md` §2 — хвост буллета про юниты
   переписан: «daemon-reload/enable/старт таймера — при `use`/`install`/`on`
   (fix-r2, инцидент evo EXP-009-хвост: без enable после ребута юниты
   disabled); linger — только `on`/`install`». Зеркало — буллет 4.4 в
   `AGENTS.md` (одна строка: enable перенесён в use/install/on, linger —
   on/install).
2. **Микрополиш (Blocking 2)**: `lib/units.sh` — две enable-строки слиты в
   одну `systemctl --user enable serve.service watchdog.timer`
   (watchdog.service — static, без [Install]: живой systemd mixed-enable
   молча пропускает — юнит поднимается таймером, enable был бы no-op);
   докстринг/коммент-контракт обновлены («enable двух юнитов», static-примечание).
   `tests/run_checks.sh` §18: лог-ассерт на enable serve+timer; артефакт-ассерт
   wants-симлинков 3 → 2 (serve.service + watchdog.timer) + однострочный
   комментарий «watchdog.service static — поднимается таймером, enable не
   имеет эффекта».

DoD раунда 3:
- батарея **367/0 ×2** (счётчик не менялся — ассерты заменены 1:1);
- мутационная защита §18 своим прогоном на копии: удалены enable-строки →
  **365/2** («use: enable serve+watchdog.timer не вызван» + «wants-симлинки
  после use отсутствуют») — ловится;
- `bash -n` зелёный;
- дифф раунда = только перечисленные строки: `.dev/SPEC.md` (1 строка),
  `AGENTS.md` (1 строка), `lib/units.sh` (enable-слияние + докстринги),
  `tests/run_checks.sh` (§18 два ассерта). Машины не тронуты, коммитов нет.
- Note 2 review: забота о boot-гонке enable'нутого watchdog.service и
  proposal «disable watchdog.service в off/uninstall» сняты (юнит static —
  enable'лся только в faux, живьём симлинка нет); EXP-критерий «watchdog.service
  = static — норма».
