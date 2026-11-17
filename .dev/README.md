# Blackboard gfctl (dev-flow)

Карта каталога `.dev/`:

| файл | назначение |
|---|---|
| `SPEC.md` | UX/CLI-спецификация (цели, команды, профили, гейты, agent-check, отличия от hfctl) — DRAFT к согласованию |
| `PLAN.md` | 4 этапа разработки с DoD и приёмочными машинами |
| `STATE.md` | трекер «что сделано» (создаётся оркестратором при старте этапа 1) |
| `DECISIONS.md` | решения с датами (создаётся при первом решении) |
| `FACTS.md` | проверенные факты о gufo (создаётся по мере накопления) |
| `tasks/<stage>/<stage>.<sub>/` | документы сабстэджей |
| `external/` | EXP-очередь (приёмки на che-evo / che-FAEX1) |
| `archive/` | архив закрытых документов |

Источники истины снаружи репо:
- `/workspace/llm-lab/.dev/AGENT-CONFIGS.md` — конфиги профилей;
- `/workspace/llm-lab/.dev/BENCH.md` — числовые референсы;
- `/workspace/llm-lab/flash-next-engines.md` — итоги сравнения движков.
