# gfctl — деплой и управление gufo-сервером (продукт)

Продукт: CLI `gfctl` для постановки и обслуживания сервера **gufo**
(`ghcr.io/gufo-org/toolboxes/gufo-runtime`) на «голой» Ubuntu/Debian
(AMD Strix Halo / gfx1151) с моделями **qwen3.8-27B** и
**qwen3.8-flash-next**, соло и мульти, под агентские сценарии.

Сестринский продукт к `hfctl` (движок hipfire): та же философия — официальный
образ движка, никаких форков; gfctl только скачивает веса, генерирует юниты,
конфигурирует и администрирует. Проектирование — в llm-lab; приёмка — на
che-evo (60 GiB) и che-FAEX1 (128 GB).

Язык ответов — русский. Ответы подробные — но на простых задачах коротко и
по существу.

## Лейаут 4.4: одна папка = git-клон = стек

- `STACK_DIR` = каталог gfctl-файла (`readlink -f`, не cwd; `GFCTL_DIR`
  переопределяет). Запуск из любого подкаталога клона и через симлинк.
- Данные сервера — в `.data/` клона (вне git): `models/{27b,flash}`,
  `cache/<профиль>`, `logs/`; канон `.env` и маркер `.gfctl-stopped` — в
  корне клона. **Данные — инвариант**: uninstall и `git clean -fd` их не
  трогают; `git clean -fdx` ЗАПРЕЩЁН (bootstrap при каждом запуске
  проверяет `.gitignore` — без `.data/`+`logs/` печатает warn).
- Bootstrap «первого запуска»: любой вызов `./gfctl` создаёт каркас
  `.data/` (юниты НЕ ставит); systemd-юниты ставят `use`/`install`
  идемпотентно — после записи канона; daemon-reload/enable/старт таймера —
  `use`/`install`/`on` (fix-r2: без enable после ребута юниты disabled);
  linger — `on`/`install`.
- `install.sh` упразднён (4.4): доставка = git clone; полный снос стека —
  руками (`rm -rf` клона + `podman rmi`).
- `uninstall` (v2): контейнер + юниты + watchdog + linger + limits.d-файл;
  purge-флагов нет. Исключения вне клона описаны в
  `.dev/tasks/4/4.4-layout-python-decision.md` (таблица инварианта).

## Что в репо

- `gfctl` — диспетчер (env-конфигурация + bootstrap + source модулей +
  dispatch).
- `lib/` — модули: profiles, models, state (канон), serve, units,
  health, agentcheck, autostart/watchdog, commands.
- `tpl/` — systemd-юниты (serve/watchdog/timer), python-харнесы (watch,
  agent-check, gguf-type-check, smoke), bench-фикстура (канон
  `253c7ac5`), env-шаблон.
- `.dev/` — blackboard dev-flow: SPEC.md, PLAN.md, STATE.md, DECISIONS.md,
  FACTS.md, tasks/, external/ (EXP-очередь), archive/.

## Development protocol: dev-flow

- **Blackboard**: `/workspace/gfctl/.dev/` (карта — `.dev/README.md`).
- **Internal checks**: `bash -n gfctl lib/*.sh`; `python3 -m py_compile
  tpl/python/*.py`; `gfctl` без аргументов → usage, rc=1; `gfctl status
  --json` при недоступном порте — корректный отказ, не краш. Зависимостей
  нет (bash + python3 stdlib + podman на цели).
- **External checks** (BLOCKED-EXTERNAL): всё, что требует живого контейнера
  или хоста — приёмка только через EXP-скрипты + явное GO пользователя
  (машины che-evo/che-FAEX1 принадлежат llm-lab, не здесь).
- **Environment hygiene**: роли не делают ssh/podman наружу, не трогают
  /workspace/llm-lab, не коммитят (коммиты — оркестратор), не правят
  `.dev/STATE.md` (обновляет оркестратор).
- **Code conventions**: как в hfctl — bash-комментарии
  `# Назначение / Побочные эффекты / Ограничения / @param / @stdout / @returns`
  на русском; python — только stdlib, один файл = одна роль в `tpl/python/`;
  в репо нет IP, имён хостов, путей ключей.

## Источники истины для профилей

- `/workspace/llm-lab/.dev/AGENT-CONFIGS.md` — оптимальные конфигурации
  агентского сценария (проверены окнами FX/HX/CX 2026-11-17); профильная
  таблица gfctl (SPEC §5) не вправе расходиться с ним без нового окна.
- `/workspace/llm-lab/.dev/BENCH.md` — все числовые основания.
- Правило квантов: unsloth UD-* GGUF НЕ грузятся gufo (IQ2_S/IQ3_XXS в FFN,
  подтверждено дважды) — 27B только pure-IQ4_XS (jpetrina) или K-quant;
  любой новый сет весов проходит pre-check типов (`gguf_type_check.py`).

## Правила разработки

1. Любое изменение целевой конфигурации — через профильную таблицу gfctl,
   не руками в юнитах.
2. После смены конфига — recreate + wait_health + smoke (порядок
   фиксированный).
3. Живой прод на приёмочной машине останавливается только внутри приёмки
   этапа (машины с hfctl-продом: `hfctl off` до окна, `hfctl on` после).
4. Найденные в догфуфе баги — правка + коммит в тот же этап, заметки в
   AGENTS.md.
