# Brief: 1.2 жизненный цикл gfctl — serve-юниты + install/use/on/off/uninstall + smoke/logs + watchdog/boot

## Goal (statable, checkable)
На каркасе 1.1 работает полный жизненный цикл сервера как ЕДИНЫЙ локальный
флоу (без живой GPU-машины — вся podman/systemd/loginctl-логика тестируется
через PATH-заглушки, реальный прогон — EXP этапа):
- `gfctl install [--profile P] [--port N] [--bind A] [--models-dir D]
  [--no-autostart]`: preflight-гейты → докачка весов профиля (lib/models)
  → генерация systemd-user юнитов из tpl/ → старт контейнера (podman run
  с флагами F9) → health → smoke → автозапуск (boot-юнит + linger),
  если не `--no-autostart`. Идемпотентен (повтор поверх работающего —
  recreate без дублей юнитов).
- `gfctl use <профиль> [--sessions N] [--context N] [--no-probe]`: гейты →
  ленивый добор весов → перегенерация serve-юнита → recreate (rm+run,
  пауза/ретрай из-за F10) → health → smoke; канон профиля пишется в
  `~/gufo/.env` (`GFCTL_PROFILE` + sessions/context). Probe-подбор
  контекста — ЭТАП 2; в 1.2 `--no-probe` не существует, context/sessions —
  из профильной таблицы (overrides сохраняются в канон).
- `gfctl on` / `off`: автозапуск вкл (юниты enabled + linger) / стоп +
  disable + linger off + маркер `~/gufo/.gfctl-stopped` (F11: linger off
  только в явном off; вотчдог маркер уважает — F16).
- `gfctl _watchdog`: вызов таймером 1 мин; если маркера нет и контейнер
  не healthy → поднять. Boot-юнит поднимает канон профиля при загрузке.
- `gfctl uninstall [--purge-models] [--purge-image]`: слои — контейнер →
  юниты+timer → limits.d → `~/gufo` (модели щадятся по умолчанию; образ
  только с явным флагом).
- `gfctl logs [-f] [N]`: podman logs контейнера.
- `gfctl smoke`: health-предикат (строка `load_completed` в логе, F2:
  `--host 0.0.0.0`) + 3 запроса (код/проза/математика) + печать роута
  (`speculative=…, sessions=…, context_tokens=…`); ретрай первого запроса
  через 15 с (F15). rc≠0 при отказе.
- `gfctl status [--json]` — живой режим: фактический роут из лога,
  cache-каталог, версия образа, автозапуск; замороженная схема JSON из 1.1
  расширяется БЕЗ ломания (null'ы при мёртвом сервере сохраняются).
- Скрытые алиасы `up|down` = use-канон-профиля / off (вернуть потерянное
  из PLAN).

## DoD (checklist)
- [ ] `install`/`use`/`on`/`off`/`uninstall`/`logs`/`smoke`/`_watchdog`
      реализованы; заглушки 1.1 сняты ровно для этих команд (bench/
      agent-check/cache/watch остаются заглушками этапов 2–3).
- [ ] tpl/: serve-юнит (oneshot up + RemainAfterExit или эквивалент),
      watchdog .service+.timer (1 мин), boot-юнит — генерируются из
      шаблонов с подстановкой профиля/порт/путей; env-шаблон `~/gufo/.env`.
- [ ] Serve-командная строка контейнера собирается ИЗ профильной таблицы
      (веса @DRAFT@/@MTP@-токены → пути, флаги F9 ровно, порт из D2/`--port`).
- [ ] Health-предикат: чтение podman logs до строки `load_completed`
      (таймаут ~3 мин, прогресс-печатка), затем HTTP-проба порта.
- [ ] Порядок фиксированный: любая смена конфига = recreate → health →
      smoke (правило AGENTS/llm-lab).
- [ ] `off` → вотчдог НЕ воскрешает (в тестах с заглушками: маркер
      проверяется раньше подъёма); `on` возвращает всё.
- [ ] uninstall без флагов оставляет модели и образ на месте.
- [ ] Internal checks зелёные (батарея расширяется: секции для новых
      команд с PATH-заглушками podman/systemctl/loginctl/curl).
- [ ] Регресс 1.1 не сломан (все 93 прежних ассерта проходят).

## Specification references + ratified fact/decision ids
- SPEC §2 (стек `~/gufo/`), §3 (карта команд), §4 (модель состояний:
  канон профиля в .env, on/off-семантика), §6 (роут/health из лога,
  смоук-ретрай), §8 (таблица отличий: прямой podman run, recreate=rm+run,
  serve-unit + watchdog timer, маркер .gfctl-stopped), §9 (риски:
  gpu-lock без takeover — D3; медленное освобождение порта — F10).
- FACTS: F1 (инсталлятора в образе нет — качает gfctl), F2 (--host
  0.0.0.0), F9 (podman-флаги ровно как в проверенных запусках), F10
  (пауза между recreate), F11 (linger-семантика off), F15 (ретрай 15 с),
  F16 (watchdog-паттерн: unless-stopped rootless не работает).
- DECISIONS: D1 (локальная дистрибуция — install.sh каркас уже есть),
  D2 (порт 8080), D3 (никакого автопереключения с hfctl — только WARN).

## Constraints and known traps
- Роли НЕ делают ssh/podman/systemd наружу (hygiene): все вызовы внешних
  бинарей в тестах — PATH-заглушки (faux-bin каталог), в батарее. Реальные
  прогоны — EXP этапа (evo).
- `install.sh` каркас 1.1 не ломать: полный install остаётся командой
  `gfctl install`, install.sh только копирует дерево.
- Юниты systemd-user: `~/.config/systemd/user/`, `systemctl --user`;
  linger через loginctl; в заглушках проверяется ИМЕННО набор вызовов
  (enable/disable/start/stop, enable-linger).
- Не хранить IP/хосты/ключи; целевая машина GNU coreutils, юзер uid=1001.
- Профильная таблица — единственный источник serve-флагов (правило
  «Источники истины»; расхождение с AGENT-CONFIGS запрещено).
- python3.14 stdlib only; bash-комментарии в стиле hfctl.
