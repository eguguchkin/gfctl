# Brief: 3.1 agent-check + cache + watch (агентская самопроверка, кэш-сводка, дашборд)

## Goal (statable, checkable)
Три команды этапа 3 (PLAN), снимающие заглушки последними:
1. **`gfctl agent-check`** (SPEC §7): 4 проверки на живом сервере:
   (а) сессия 15 ходов (doc ~6.6k + Q→A, greedy, 128 ток, reasoning off)
   — total wall; (б) follow-up-лестница 5k/25k/100k — turn2 wall;
   (в) [док 25k][q1] → [док 25k][q2] — q2 wall (кэш-эффект); (г)
   рестарт-restore: recreate контейнера → ход того же разговора (проверяет
   cache-disk). Референсы из AGENT-CONFIGS (per профиль): 27b-single 23.8 с
   (сессия), follow-up ≤1.7 с, restore ≤1 с @27k; flash-multi 2×262144 —
   референсы снимаются EXP'ом окна этапа 2/3 (±25% → WARN). Сводка
   PASS/WARN/FAIL + подсказка причины (WARN follow-up → проверить
   cache-ram/disk).
2. **`gfctl cache [--verify]`**: сводка кэша из логов (configured/
   skipped/evicted, ram/disk capacity из строки configured — формат виден
   в EXP-005 логе: `schema=component-cache-v1 event=configured ...`)
   + `/metrics` cached_total если есть; `--verify` — контрольный follow-up
   + рестарт-проба (tmpfs-каталог кэша → WARN).
3. **`gfctl watch [--interval N]`**: TTY — TUI-дашборд (блоки «Движок»/
   «Скорость»/«Память»/«Логи»; клавиши q/+/-/p), не-TTY — стрим тех же
   блоков. Источники: /metrics gufo (`llamacpp:*`), host /sys//proc
   (RAM, hwmon-температуры), podman logs -f (draft-приём). Мёртвый
   сервер — строка «недоступен» без спама.

## DoD (checklist)
- [ ] `agent-check`: 4 проверки реализованы; референсы — из констант
      profiles/AGENT-CONFIGS (per профиль); WARN при >25% регрессии;
      rc: 0 all-PASS, 1 есть FAIL, 0 при WARN (WARN ≠ FAIL) — по SPEC.
- [ ] `cache`: сводка из логов; `--verify` ловит tmpfs-кэш (WARN) и
      делает контрольный follow-up.
- [ ] `watch`: TTY/не-TTY ветки; q — выход; мёртвый сервер — без спама.
- [ ] Заглушки сняты ровно у agent-check/cache/watch; других команд в
      usage изменения не ломают; internal checks зелёные (батарея
      расширяется, осознанные замены секции заглушек — по п.0-прецеденту).
- [ ] Регресс 1.1+1.2+2.1 цел (225 ассертов).
- [ ] EXP-заготовка окна этапа 3 (EXP-007: agent-check на flash-multi
      2×262144 с пере-снятием агентских референсов + на 27b-single evo —
      ставится в очередь, не исполняется).

## Specification references + ratified fact/decision ids
- SPEC §7 (agent-check протокол), §3 (cache/watch строки), §5 (референсы
  per профиль), §8 (watch: /metrics llamacpp:* + логи draft-приём).
- PLAN этап 3 (DoD: agent-check 4 пункта; искусственная регрессия
  cache-ram 512MiB → WARN ловится; cache --verify tmpfs WARN; watch TUI
  q/+/-/p, не-TTY стрим, мёртвый сервер без спама).
- FACTS: F12 (фикстура md5 — НЕ для agent-check, там свои промпты),
  F15 (ретрай первого), F17 (restore 0.35–0.81 c живой), F18/F20
  (референсы парного замера vs bench — не смешивать), F20 (имя модели
  с пробелами — запросы через ROUTE_MODEL).
- DECISIONS: D4/D5 (профили), D6 (окна по GO).
- Остаток этапа 2 (переносится сюда): агентские референсы flash-multi
  снимаются EXP-007 на итоговом каноне 2×262144 → константы в
  profiles/AGENT-CONFIGS (DoD этапа 2 п.4 закрывается этим).

## Constraints and known traps
- Роли не делают ssh/podman — agent-check/cache/watch тестируются через
  faux-bin (podman logs фикстуры с configured/evicted строками; curl —
  детерминированные ответы; рестарт-restore в тестах — заглушка recreate).
- Тайминги agent-check в батарее НЕ ассертить (машино-зависимы) —
  ассертить структуру вывода и пороги WARN (сравнение с референсом —
  чистая функция от чисел).
- Рестарт-restore УБИВАЕТ сессии пользователя сервера — только в окнах
  (EXP), в коде предупреждение перед recreate.
- watch TUI: bash+stdlib (ANSI-пескоструй без tput-зависимостей сверх
  GNU); не-TTY детект `[ -t 1 ]`.
- ~15 ходов сессии: HTTP-запросы последовательные; reasoning off —
  параметр запроса (как в окнах HX-A — протокол AGENT-CONFIGS п.1).
- python3 stdlib only; без IP/хостов; GNU-машины.
