# STATE gfctl (единственная точка правды «где мы сейчас»)

Текущий сабстэдж: **3.1 agent-check + cache + watch** — in-dev
(round 0/3), task.md от architect готов, запуск developer.

Closed:
- **1.1** (APPROVED r1), **1.2** (APPROVED r1) → **ЭТАП 1 ЗАКРЫТ**:
  EXP-001/002/003 PASS на evo (F17), hfctl-прод evo восстановлен.
- **2.1 probe+bench** (APPROVED r1) + **F1–F4** (все APPROVED; F1/F2
  stat -L симлинки; F3 ROUTE_MODEL с пробелами; F4 канон=факт +
  smoke-ретрай; батарея 233, ловимость каждого раунда доказана).
- **Окна этапа 2**: EXP-004 (27b-multi 163840 живой, парный агрегат
  46.3/51.0 — F18), **EXP-005 FAEX PASS** (flash-multi: 2×262144 канон —
  максимум лестницы, bench 88.5; 4×196608 канон, bench 88.1; admission
  229376@4 с цифрами; check-types DoD — F20), **EXP-006 evo PASS**
  (27b-multi probe 196608 — максимум, bench 76.3 паритет с соло — F23;
  «тихое урезание движком» ОПРОВЕРГНУТО — F21: причина — старый 1.2-код
  без bootstrap). hfctl-проды обеих машин восстановлены (healthy+smoke).
- Решения окон: FAEX — flash-only (хардлинки весов, MTP плоско в flash/);
  27b-probe — evo (D6); EXP-скрипты не запускать параллельно на машине.

Бэклог: install-probe (SPEC §3 — до этапа 4 или правка §3); хвост лога →
журнал probe; display-имена GGUF-типов + граница RED (F20-живая валидация
прошла: q4xl зелёные, ixs КРАСНЫЕ на ffn-шардах); part>pin; --check-types
лишний аргумент; JSON-экранирование; атрибуция WARN probe_context
(«тихое урезание») — переформулировать при следующем касании (F21).

Next step: developer 3.1 → tester → reviewer → **EXP-007** (агентские
референсы flash-multi на FAEX + agent-check на 27b-single evo — GO
пользователя) → этап 4 (хардening/доставка).

План: `.dev/PLAN.md` (4 этапа; этапы 1–2 по коду закрыты, окна этапа 2
прошли). Fix-round counter: F1–F4 закрыты.
