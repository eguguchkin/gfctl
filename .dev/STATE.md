# STATE gfctl (единственная точка правды «где мы сейчас»)

Текущий сабстэдж: **3.1 agent-check + cache + watch** — CLOSED
(APPROVED r1: DoD 6/6, батарея 289, curl-отклонение подтверждено Test
strategy; backlog: reuse=none ассерт при следующем касании).

Остаток этапа 2: агентские референсы flash-multi/docq → EXP-007 (окно:
FAEX flash-multi 2×262144 + evo 27b-single) → заполнить ref_* в
profiles + AGENT-CONFIGS + SPEC §5 дельта (провенанс референсов —
замечание review 3.1 Q3: 1.7/0.81 в спеке — из окна CX flash-next,
у gufo-27B другие — сверить с живым снятием).

Next step: **GO пользователя на EXP-007** → заполнение ref_* + SPEC дельта
→ этап 4 (хардening/доставка).

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
- 2026-11-18 — **EXP-007 PASS (FAEX + evo, rc-проблемы только критериев
  скрипта — исправлены: GF_ACC_FLAVOR передача, AC/CV-парсинг)**:
  flash-multi (FAEX 2×262144): agent-check 4 проверки сняты, WARN=4
  «эталон не снят» штатно; cache --verify reuse=live 0.75 / restore
  reuse=disk 0.68; факт-база /metrics полный список llamacpp:* (15
  ключей), timings подтверждён. ЧИСЛА → ref_* (flash: 17.22/1.58/10.44/
  1.89; 27b-single: 30.44/3.00/3.60/2.85) — profiles.sh обновлён,
  AGENT-CONFIGS + BENCH.md + SPEC §5 дельта сделаны. evo agent-check:
  rc=0 (PASS=0 WARN=4 — WARN-регрессии к старым ref признаны
  артефактом смешанных референсов, ref заменены). Проды обеих машин
  восстановлены (healthy+smoke). ОСТАТОК ЭТАПА 2 ЗАКРЫТ (референсы).
  Этап 3 код закрыт (3.1 APPROVED). Далее — этап 4.

План: `.dev/PLAN.md` (4 этапа; этапы 1–2 по коду закрыты, окна этапа 2
прошли). Fix-round counter: F1–F4 закрыты.
