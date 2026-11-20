# Dev report: 4.4-layout — лейаут «одна папка = git-клон = стек» + uninstall v2

- Дата: 2026-11-20
- База: HEAD `b822db54` (батарея 362/0 — базовая линия прогнана ДО правок)
- Статус: **developed** (машины не тронуты; коммитов нет — дерево грязное,
  коммит за оркестратором после review/test)

## What was done

Все 8 пунктов решения (`../4.4-layout-python-decision.md`) и brief закрыты.
Батарея 362 → **363 PASS / 0 FAIL** (дважды подряд), `bash -n`, `py_compile`
— зелёные.

### 1. STACK_DIR-детект (`gfctl`, шапка)

- `SELF="$(readlink -f "$0")"` вычислен раньше конфига;
  `STACK_DIR="${GFCTL_DIR:-$(cd "$(dirname "$SELF")" && pwd)}"` — стек =
  каталог gfctl-файла (не cwd). Механика `readlink -f`: запуск через
  симлинк (`~/.local/bin/gfctl → ~/gfctl/gfctl`) и из любого подкаталога
  клона указывает на один и тот же стек. Дефолт `$HOME/gufo` УБИРАН;
  `GFCTL_DIR`-оверрайд сохранён. `LIB_DIR`/`TPL_DIR` упрощены до
  `$(dirname "$SELF")/{lib,tpl}` (readlink -f в SELF уже разрешает симлинк).
- Пути данных: `GFCTL_MODELS` default `$STACK_DIR/.data/models`
  (было `$STACK_DIR/models`); `LOGS_DIR=$STACK_DIR/.data/logs`; кэш-тир
  — `.data/cache/<профиль>` (serve.sh container_up, status, cache).

### 2. Bootstrap «первого запуска» (`gfctl::bootstrap_dirs`)

Вызывается в верхнеуровневом скоупе при КАЖДОМ запуске диспетчера (до
source lib, от модулей не зависит): идемпотентный `mkdir -p`
`.data/{models/{27b,flash},cache,logs}` + контроль `.gitignore` клона
(точные строки `.data/` и `logs/` через `grep -Fqx`; отсутствие файла или
строк → warn «git clean -fdx ЗАПРЕЩЁН»). Юниты НЕ ставит, канон `.env` не
пишет. Юниты ставит `use`/`install`: в `cmd_use` добавлен `install_units`
сразу после `write_canon` (лейаут 4.4: юниты — после канона;
идемпотентный рендер; enable/linger по-прежнему только `on`/`install` —
батарейный ассерт «use не зовёт systemctl» сохранён). `install` уже ставил
юниты — не менялся.

**Решение в рамках свободы brief** (задача разрешала выбрать):
команда `install` ОСТАВЛЕНА (полная постановка с автозапуском,
идемпотентна — ~60 батарейных ассертов на ней); quickstart — `use`.
Батарею это не ломает и код не дублирует.

### 3. install.sh упразднён

`install.sh` удалён из репо. README/AGENTS/SPEC переписаны под
`git clone → cd gfctl → ./gfctl use <профиль>` (URL — из brief; реальный
GitHub-клон не проверялся — см. «не проверено живьём»). WARN probe-факта
(`commands.sh`, F21-подсказка) теперь говорит «обнови дерево (git pull
клона)» вместо `./install.sh`.

### 4. Uninstall v2 (`cmd_uninstall` переписан)

Слои: маркер+container_stop → disable+rm юнитов (serve+watchdog+таймер)
+daemon-reload → linger off → `sudo rm -f /etc/security/limits.d/99-gfctl-memlock.conf`.
**НЕ трогает**: дерево клона целиком (`.data/`, канон `.env`, сам gfctl) и
podman-образ. Согласие ask сохранено (не-TTY без GFCTL_YES → rc 1, ничего
не снято).

Решения в рамках свободы brief:
- **purge-флаги `--purge-models`/`--purge-image` УПРАЗДНЕНЫ** (лишний
  аргумент → die): decision rule 5 «полный снос — руками: папка +
  `podman rmi`»; итоговая сводка печатает ручной снос и путь возврата
  (`cd <клон> && ./gfctl use <профиль>`).
- **limits.d-файл снимается** (brief v2 «+limits.d-файл», decision rule 5
  «снимает юниты/контейнер/limits.d»): против прежнего 4.1-F2-поведения
  «не трогаем» — это осознанная смена границы; файл возвращается при
  следующем install/use из memlock-гейта, цикла install↔uninstall нет
  (гейт ≥ порога продолжает установку). Таблица исключений инварианта в
  decision («останется при удалении папки») осталась верной — она про
  ручной снос папки, не про uninstall.
- «Слоёный» снос дерева `~/gufo` и приёмочных `~/gfctl-acc{,-src,-models}`
  убран. Детекция «соседних артефактов» в doctor ОСТАВЛЕНА (read-only
  инвентарь полезен окну миграции), примечание переписано: «uninstall (v2)
  не трогает НИКАКИЕ данные…».

### 5. .gitignore репо (правило 6)

Добавлены `.data/` и `logs/` с комментом «git clean -fd безопасен, -fdx
запрещён». Проверено `git check-ignore` — skeleton, созданный ручными
прогонами диспетчера в корне репо, git-игнорится (и из рабочего дерева
удалён).

### 6. SPEC.md (owning spec — граница изменена)

§1 (путь новичка), §2 (дистрибуция/лейаут/инвариант), §3 (строка
uninstall v2), §4 (канон `<клон>/.env`) переписаны под лейаут 4.4.
`spec_validate` не запускался — в репо gfctl спека живёт обычными .md без
frontmatter-графа (dev-flow blackboard), структурных правок графа нет.

### 7. Review-fix: render_tpl печатает путь шаблона

`lib/units.sh` (pre-existing units.sh:30): после `shift 2` `$1` в
`die "нераскрытые плейсхолдеры в шаблоне $1"` был ПЕРВОЙ ПАРОЙ, не путём.
Фикс: `tpl_path="$1"` захвачен до shift. Батарейный ассерт §16 проверяет
наличие пути шаблона в FATAL.

### 8. Батарея (362 → 363; все пути-ассерты под `.data/`)

- Harness `gf`: `MODELS_BASE=$TMP/stack/.data/models`, `LOGS_DIR=.data/logs`;
  канон-фикстура `.gitignore` в `$TMP/stack` (bootstrap-варн молчит вне
  негативного теста).
- §13 переписан (install.sh-секция, 4 ассерта → 8 новых): (а) bootstrap
  первого запуска создаёт каркас `.data/{models/{27b,flash},cache,logs}`
  БЕЗ юнитов и БЕЗ канона; (г) STACK_DIR-детект из подкаталога клона
  (без GFCTL_DIR) и через симлинк; негатив `.gitignore` → WARN;
  `install.sh` упразднён из репо. Старый ассерт «фикстура bench = копия
  hfctl» ушёл вместе с секцией — канон фикстуры по-прежнему guarded в §32
  (md5-гейт 253c7ac5).
- §14: `.env`-want с `__MODELS_DIR__=$TMP/stack/.data/models`; §17:
  CANON_RUN с маунтами `.data/models/27b` + `.data/cache/27b-single` и
  `Environment=GFCTL_MODELS=.data/models` в юнитах (defect EXP-009
  ассерты); §18: +2 ассерта «(б) юниты ставятся при use» + GFCTL_DIR
  юнита = стек-клон; §20/26–28/34/36: watchdog.log/probe-журналы/state-файлы
  под `.data/logs/`; §25/35: кэш-пути (grep-суффиксы совместимы).
- §24 переписан (в): uninstall v2 НЕ сносит `.data/` и клон; limits.d
  снят; rmi отсутствует; purge-флаги → die; отказ без согласия → rc 1.
  §41 переписан: acc-каталоги и пулы `~/gufo-models ~/gufo-exp
  ~/halogen-*` НЕ тронуты uninstall'ом.
- §38: quickstart-паттерны `./gfctl <cmd>` + `git clone`; §39: ассерты
  нового примечания doctor (purge-упоминаний больше нет).
- Итог: **363 PASS / 0 FAIL ×2 прогона** (лог: `ИТОГО: PASS=363 FAIL=0`).
- **fix-r1 (тест §18, рецепт tester)**: §17-install кладёт юниты в тот же
  `$ud` харнесса, поэтому ассерт «use ставит юниты» не ловил регрессию
  «use перестал ставить юниты». Перед `cmd_use` в §18 добавлен
  `rm -f` трёх юнитов (1 строка + коммент). Проверено мутацией на копии
  репо (удалён `install_units` из cmd_use): §18 падает ровно двумя FAIL
  («use не поставил юниты», «use юниты GFCTL_DIR») → 361/2; на чистом коде
  363/0 ×2. Прод-код fix-r1 не трогал — только тест.

## DoD-сводка

| пункт | результат |
|---|---|
| батарея 362+N зелёная ×2 | ✅ 363/0, два прогона подряд |
| `bash -n gfctl lib/*.sh` | ✅ (внутри батареи §1 + отдельно) |
| `py_compile tpl/python/*.py` | ✅ (§1 + отдельно) |
| `git diff` ограничен перечисленными файлами | ✅ — см. «Вне перечисленных файлов» ниже (2 помеченных исключения) |

Файлы дельты: `gfctl`, `lib/{commands,serve,state,units}.sh`,
`tests/run_checks.sh`, `.gitignore`, `README.md`, `AGENTS.md`,
`install.sh` (удалён), `.dev/SPEC.md`,
`.dev/external/EXP-00{8,9}-*.sh`, `tpl/systemd/gfctl-{serve,watchdog}.*.tpl`.
Не коммитил; машины не трогал.

## Вне перечисленных файлов (пометка по правилу скоупа)

1. `.dev/SPEC.md` — owning spec: граница лейаута/uninstall изменена,
   разделы §1/§2/§3/§4 обновлены в этом же дельта-коммите (требование
   протокола спек).
2. `tpl/systemd/*.tpl` — только 2 строки комментариев юнитов: упоминание
   дефолта `$HOME/gufo` (дефект EXP-009) стало ложным в рендеренных
   юнитах; заменено на «каталог gfctl-файла». Контент юнитов (Environment/
   ExecStart) не менялся — все ассерты §17/§18 зелёные без правок.
3. `.dev/PLAN.md` НЕ правил: записи этапа 4 — история исполненных окон
   EXP-008/009 со старым лейаутом. Предложение (out-of-scope): оркестратору
   добавить в PLAN короткую заметку «4.4 — лейаут перепроектирован, см.
   tasks/4/4.4-layout-python-decision.md».

## EXP-008/009 (REPLANNED, минимальные правки)

Шапки (GOAL/REPLANNED/PREREQ) и тела подведены под `~/gfctl` + `.data/`:
tar → `~/gfctl` (excludes `.git/.dev/.data`), `GFCTL_DIR`/`GFCTL_MODELS`
оверрайды сняты (детект сам), хардлинк-цель `~/gfctl/.data/models/<сет>`,
watchdog-лог `~/gfctl/.data/logs/watchdog.log`, шаг install.sh заменён
«bootstrap первого запуска — сам диспетчер (`gfctl status`)».
`bash -n` обоих скриптов зелёный. Пулы `~/gufo-models`/`~/gfctl-acc-models`
оставлены источниками хардлинков — до окна миграции.

## Что НЕ проверено живьём (EXP / BLOCKED-EXTERNAL)

- **Миграция машин (FAEX/evo `gfctl-acc` → `~/gfctl`) — вне подэтапа**:
  окно оркестратора. Ожидание по decision rule 7: gufo стоп → `mv
  gfctl-acc/* ~/gfctl/` с переносом моделей в `.data/` (mv сохраняет
  иноды хардлинков) → юниты перерендерятся при первом use → healthy.
- Живой podman/systemctl/sudo/loginctl: uninstall-слои на реальной машине
  (в т.ч. `sudo rm limits.d` и повторный install после него) — только
  faux-проверено.
- Живой systemd-путь юнитов (serve `_boot`, watchdog) после перехода на
  юниты-из-клона: ExecStart=`bash <клон>/gfctl _boot` рендерится, но
  ребут-приёмка (EXP-009) не исполнялась.
- `git clone https://github.com/eguguchkin/gfctl` — репо на GitHub пока не
  существует; URL взят из brief, живой клон не проверялся.
- Мультипрофильный probe на реальном GPU с новыми путями (батарея
  покрывает механику через faux; живые числа — окна EXP).

## Инструкции для reviewer

- Ключевые диффы: `gfctl` (шапка+bootstrap), `lib/commands.sh`
  (cmd_use:install_units, cmd_uninstall v2, doctor-примечание),
  `tests/run_checks.sh` (§13/§24/§41).
- Осознанные смены поведения против прошлого кода (все — по decision/brief):
  uninstall снимает limits.d-файл; purge-флаги убраны; use ставит юниты;
  дефолт моделей `.data/models`; doctor-примечание новое.
