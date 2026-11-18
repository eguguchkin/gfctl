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
