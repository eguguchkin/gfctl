# Brief: 1.1 каркас gfctl — диспетчер + lib/ + профильная таблица + models + гейты + диагностика

## Goal (statable, checkable)
На чистом каталоге `/workspace/gfctl/` существует работающий CLI `gfctl`
(диспетчер + `lib/` + `tpl/python/gguf_type_check.py`), в котором
функционируют ТОЛЬКО read-only/подготовительные команды:
- `gfctl` без аргументов → usage, rc=1;
- `gfctl models` — инвентарь весов по сетам (есть/нет по пути+размеру+sha-статус,
  свободное место);
- `gfctl models download <set>` — докачка с pre-flight «нужно X GiB», curl
  resume, sha256-verify после;
- `gfctl models --check-types` — pre-check GGUF-типов тензоров (красный на
  IQ2_S/IQ3_XXS/неизвестных в ffn_* тензорах);
- `gfctl doctor` — диагностика без записи (см. DoD);
- `gfctl status [--json]` — профиль/гейты/веса + health: «не запущен»
  (серверная часть — сабстэдж 1.2);
- serve-юниты, install/use/on/off/uninstall/smoke/bench — ВНЕ scope (1.2).

## DoD (checklist)
- [ ] Диспетчер: `gfctl` (usage rc=1), `gfctl <garbage>` → rc=1 со списком
      команд; dispatch по модулям; `--help`.
- [ ] Профильная таблица (`lib/profiles.sh`): 3 профиля (`27b-single`,
      `27b-multi`, `flash-multi`) с весами, serve-флагами, RAM-гейтами
      — константы, байт-в-байт соответствие SPEC §5 и AGENT-CONFIGS пп.3–4.
- [ ] `gfctl models`: инвентарь (файл/размер/sha-статус/свободно), `download`
      с цифрами до трафика и sha-verify после (resume при обрыве).
- [ ] `gfctl models --check-types`: на скачанных flash-шардах → КРАСНЫЙ
      IQ2_S/IQ3_XXS в ffn; на pure-IQ4_XS 27B → зелёный; на Q4_K_XL
      flash → зелёный. (Проверяется синтетическими мини-GGUF фикстурами,
      без реальных весов.)
- [ ] `gfctl doctor`: ОС, /dev/kfd, render-группа, memlock, linger, RAM-гейты
      ВСЕХ профилей цифрами («27b-single: ≥56 GiB — есть 59.5: OK»),
      диск под веса, порт 8080, gpu-lock WARN (кто держит /dev/kfd).
- [ ] `gfctl status --json` — валидный JSON при мёртвом сервере.
- [ ] Internal checks (см. AGENTS.md «Internal checks») — зелёные.

## Specification references + ratified fact/decision ids
- SPEC §2 (дистрибуция/стек `~/gufo/`), §3 (карта команд — строки models/
  doctor/status), §4 (состояния), §5 (профили+запреты), §8 (отличия), §9
  (риски/gpu-lock).
- FACTS: F1 (инсталлятора в образе нет), F3 (UD-* не грузятся — raison
  d'être check-types), F8 (все веса+sha256 пины), F9 (podman-флаги),
  F13 (2×262144 отказ 27b), F14 (RAM/device машин — гейты), F12 (фикстура
  md5 — константа на будущий bench).
- DECISIONS: D1 (локальная дистрибуция), D2 (порт 8080), D4 (flash только
  мульти), D5 (27b-multi 163840, probe 196608).

## Constraints and known traps
- Роли НЕ делают ssh/podman наружу (AGENTS «Environment hygiene»); всё
  проверяется локально, синтетические фикстуры для check-types.
- Целевые машины: юзер uid=1001, GNU coreutils; python3.14 stdlib only.
- check-types парсит GGUF header потоково (шарды 49 GB — читать только
  начало файла; лимит чтения метаданных ~64 MiB, дальше abort с ошибкой
  формата).
- Доки целевой машины — GNU; не использоватьBusyBox-совместимость.
- Никаких IP/имён хостов/ключей в коде (правило 7).
- Профильная таблица — единственный источник конфигов; расхождение с
  AGENT-CONFIGS запрещено (правило из AGENTS.md «Источники истины»).
- Диспетчер по образцу hfctl: env-конфигурация в шапке + source lib +
  dispatch; стека-каталог `~/gufo/` — на этом этапе только константы путей.
