# STATE gfctl (единственная точка правды «где мы сейчас»)

Обновлено: 2026-11-18 (вечер). Этапы 1–3 закрыты, 4.1 APPROVED, EXP-007 закрыт.

## Текущий статус

- **Этапы 1–3: ЗАКРЫТЫ** (1.1/1.2; 2.1 probe+bench + F1–F4; 3.1 agent-check+cache+watch;
  окна этапа 2: EXP-004/005/006 PASS, **EXP-007 PASS** — агентские референсы сняты и
  внесены: flash 17.22/1.58/10.44/1.89; 27b-single 30.44/3.00/3.60/2.85; остаток
  этапа 2 закрыт).
- **Этап 4 (харденинг/доставка): 4.1 APPROVED** (F1-зеркало GFCTL_MIRROR_BASE,
  F2-memlock-гейт 8388608, F4-канон=факт + smoke-ретрай). EXP-008/009 — в очереди,
  требуют перепланировки: машины ai-мигрированы (hipfire-прод под ai на 11435,
  юзер hipfire retired — см. llm-lab STATE).

## Бэклог (актуальный срез 2026-11-18)

Пачка мелких код-правок — **4.2 ЗАКРЫТА (APPROVED r1, r e76ed9a)**: install-probe реализован
(идемпотентный гейт), хвост лога в журнал, GGUF display+RED по канону ggml.h (29=IQ1_M, 30=BF16),
part>pin (sha арбитр), --check-types die, json_str, WARN probe_context по F21, reuse=none ассерт.
Батарея 336→358 (tester + reviewer независимо). Некритичные остатки ревью — в review.md.
Живой probe-install — за EXP-008.

## Next (этап 4)

1. **Перепланировать EXP-008/009 под ai-расклад** — **ПЕРЕПЛАНИРОВАНО (2026-11-18)**:
   заготовки EXP-008/009 обновлены (ai/пути /home/ai, hfctl off под ai + возврат linger,
   хардлинки из ~/gufo-models + ~/gfctl-acc-models, EXP-009 фаза 1 = hfctl off → linger →
   gfctl on → ребут [старая фаза off была дефектна: снимала юниты и linger], оговорки
   device-mismatch «не грозит по дизайну — container_up всегда rm+run» и GPU-ready) →
   дельта: `.dev/tasks/4/4.2-EXP-replan.md`, отчёт: `4.2-EXP-replan-report.md`.
## Next (этап 4)

1. **Перепланирование EXP-008/009** — ВЫПОЛНЕНО (ai-расклад) → `4.2-EXP-replan.md`.
2. **FAEX-часть ПРОЙДЕНА (2026-11-18 вечер)**: EXP-008 PASS (доставка с нуля flash-multi;
   pull-висяк blob-CDN — kill+retry; agent-check 4/4, реф. EXP-007 сошлись; digest-пин
   sha256:99e9b547…) + EXP-009 PASS (ребут: самоподъём gufo; инцидент выявил DEFECT
   serve-юнит-Environment → код закрыт r bc991f1 + **принят живым ребутом 2026-11-19 01:25**,
   journal чист). hipfire-прод возвращён (healthy 30 с).
3. **Повтор на evo — ОПЦИЯ (PLAN стр. 6)**: FAEX-приёмки полные — доставка из **GitHub-клона 2cbb544**
   (клон→install→use recreate→agent-check) + **живой ребут с юнит-Environment** (самоподъём, journal
   чист) — 2026-11-19 ночь. evo-повтер (27b-single, 60 GiB) — при желании отдельным окном.
4. Финал: пуш сделан пользователем. 4.3-хвост review r1 — fix-r1 ЗАКРЫТ (формулировки по F25,
   цитаты ggml.h 431–432, батарея 361/0).

Fix-round counter: F1–F4 + fix-r1 (hfctl) закрыты. Правило касания батареи: reuse=none ассерт (есть §45).

Fix-round counter: F1–F4 + fix-r1 (hfctl) закрыты. Правило касания батареи: reuse=none ассерт (есть §45).

## Закрыто ранее (кратко)

- Этап 1 (1.1/1.2) — EXP-001/002/003 PASS на evo (F17), hfctl-прод восстановлен.
- Этап 2: EXP-004 (27b-multi 163840, агрегат 46.3/51.0 — F18), EXP-005 FAEX
  (flash-multi 2×262144 канон, bench 88.5; 4×196608 канон, 88.1 — F20), EXP-006 evo
  (27b-multi probe 196608, bench 76.3 — F23; «тихое урезание» — F21 ОПРОВЕРГНУТО).
- 2026-11-18 (hipfire-контекст, записи в history.md): миграция продов обеих машин
  на юзера ai (канон-установка, FACTS F24), живой ребут-цикл — фон для
  перепланировки EXP-008/009.

План: `.dev/PLAN.md` (4 этапа). Next: 4.2 backlog-polish → перепланировка EXP-008/009 → окна → финал этапа 4.
