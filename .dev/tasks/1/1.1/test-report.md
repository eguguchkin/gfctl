# Test report: 1.1 каркас gfctl — диспетчер + lib/ + профильная таблица + models + гейты + диагностика

**Verdict: PASS**

- Дата: 2026-11-17 · тестер · полный регресс сабстэджа 1.1 (перепрогон ВСЕГО,
  не только чек-листа developer'а): батарея ×2 + самостоятельный повтор
  каждого ключевого чека. Живые машины не трогались (ssh/podman наружу —
  нет; hygiene AGENTS.md соблюдена: мои артефакты — dangling-симлинк
  `~/.local/bin/gfctl` и `__pycache__` от батареи — удалены по завершении).

## Internal checks

| # | DoD-пункт (brief) | проверка (команда) | результат |
|---|---|---|---|
| 0 | Вся батарея | `bash tests/run_checks.sh` — **13 секций**: (1) AGENTS internal: `bash -n`+`py_compile`; (2) диспетчер bare/garbage/--help/заглушки; (3) фикстуры = регенерация байт-в-байт (10 шт, анти-дрейф); (4) парсер на мини-GGUF (числовой RED-контракт: red/green/warn/не-GGUF/усечённые/вложенный-KV/бюджет-64MiB/санити-n_kv); (5) check-types уровень gfctl (красный/зелёный/пустой/flash); (6) профильная таблица 27 полей × 3 профиля = литералам task.md + resolve/ram_gate_line/models_dir_for; (7) таблицы весов = литералам task.md + контроль сумм; (8) inventory пустой/битой/`.part`; (9) download_file file://: pre-flight/PASS/resume/SKIP/SHA-MISMATCH; (10) download не-TTY авто-нет; (11) doctor без GPU/podman; (12) status --json + человеко-строка; (13) install.sh раскладка/повтор/вне дерева | **ИТОГО PASS=93 FAIL=0, rc 0** — прогнана дважды (стабильна) |
| 1 | Диспетчер: usage rc=1 | `./gfctl` (bare) | rc=1, usage в stdout, stderr пуст ✓ |
| 1 | `gfctl <garbage>` → rc=1 + список | `./gfctl zzz_bogus` | rc=1, «неизвестная команда 'zzz_bogus'. Команды: …» + «Профили: 27b-single 27b-multi flash-multi» ✓ |
| 1 | `--help` → rc 0 | `./gfctl --help` | rc=0 ✓ |
| 2 | Профильная таблица = SPEC §5 / AGENT-CONFIGS пп.3–4 | батарея сек. 6 (27 полей) + **ручная сверка** с SPEC §5 и llm-lab AGENT-CONFIGS пп.3–4: `27b-single` serve-строка 1:1 (dflash2, sessions 1, ctx 262144, cache-ram 12884901888, cache-disk 68719476736); `27b-multi` = D5 (163840, лестница от 196608 — F13, cache-ram 4 GiB); `flash-multi` = п.4 (mtp, sessions 2, лестница 262144→131072, cache-ram 4G + disk 64G); RAM-гейты 56/110 = SPEC §5 hard rules; cache-disk 27b-multi 64G = ратифицированное OQ№1 | соответствие ✓ (3 профиля, байт-в-байт) |
| 3 | models inventory | `GFCTL_MODELS=<tmp> ./gfctl models` | пустой → 7×«НЕТ» + сводка по 3 профилям, rc 0; размеры/статусы по пинам ✓ |
| 3 | download pre-flight «нужно X GiB» ДО трафика | `download_file file://… 10995116277760 …` (ручной, поверх батареи сек. 9) | «нужно 10240.0 GiB (остаток), свободно 0.5 GiB» + WARN → rc=1, `.part` НЕ создан, сеть не тронута ✓; реальный HF — не запускался (EXP-002) |
| 3 | sha-verify / resume / SKIP | file:// транспорт: PASS+sha OK+байты совпали; `.part` 75% → докачка → цельный файл; SKIP при совпавшем размере ✓ |
| 3 | SHA-MISMATCH удаляет файл+.part | кривой `.part` + чужой sha → rc=1, **dest и dest.part удалены**, WARN с рецептом «перекачай: gfctl models download <сет>» ✓ |
| 4 | check-types: IQ2_S в ffn → красный | `python3 tpl/python/gguf_type_check.py tests/fixtures/gguf_ffn_iq2_s.gguf` (фикстура type **22**, в RED-наборе {16,17,18,19,22,25,26}) | rc=1 + `RED: … ffn blk.0.ffn_gate.weight = IQ2_S` + на уровне gfctl rc=1 «КРАСНЫЙ — не загрузится…» ✓ |
| 4 | IQ4_XS → зелёный | `…gguf_ffn_iq4_xs.gguf` (type 23) | rc=0 «зелёный»; уровень gfctl rc=0 ✓ |
| 4 | не-GGUF → rc 2 | `…gguf_not_gguf.gguf` | rc=2 «ОШИБКА ФОРМАТА: не GGUF (магия)» ✓; усечённый/вложенный-KV/бюджет/санити — тоже rc 2 ✓; risky вне ffn → rc 0 + WARN-строка ✓ |
| 5 | doctor: RAM-гейты всех профилей цифрами, без краша на хосте без GPU/podman | `./gfctl doctor` (ручной, контейнер 31.3 GiB, нет kfd/renderD/loginctl/podman) | rc=0; «27b-single: ≥56 GiB — есть 31.3: НЕДОСТАТУПЕН» ×2 + «flash-multi: ≥110 GiB — есть 31.3: НЕДОСТАТУПЕН»; диск ×2 («нужно 14.6/106.3 GiB»); порт 8080; gpu-lock «?»; ни traceback, ни FATAL ✓ (живые значения — EXP-001) |
| 6 | status --json валиден при мёртвом сервере | `GFCTL_PORT=8198 ./gfctl status --json \| python3 -m json.tool` | rc=0; JSON валиден; схема: health=«не запущен», route/autostart/version=null, gates — 3 профиля, models totals 2/5 ✓; человеко-строка одной строкой ✓ |
| 7 | Internal checks AGENTS.md | `bash -n gfctl lib/*.sh` → rc 0; `python3 -m py_compile tpl/python/*.py` → rc 0; usage rc=1; status при мёртвом порте — корректный отказ | все зелёные ✓ |
| — | **Нет преждевременного кода 1.2** | `ls lib/` = {commands,models,profiles}.sh; нет `lib/serve.sh`/`health.sh`/`autostart.sh`, нет `tpl/systemd/`; в commands.sh нет unit-generation/serve-логики; 11 заглушек (`install use logs watch on off uninstall bench smoke cache agent-check`) → каждая **rc=1** с текстом «появится в сабстэдже 1.2 / этапе 3»; скрытых алиасов `up/down` нет (по task.md; упоминание в PLAN — осознанно не реализовано, бэклог 1.2) | ✓ грамматика заморожена, ничего лишнего |
| — | **Пины весов = task.md §models / F8** | батарея сек. 7 (cmp байт-в-байт) + ручной пересчёт: все sha — **полные 64-hex**; `27b` = 15 677 391 456 B ✓ (исправленное значение оркестратора); flash шарды = **111 334 654 778 B** ✓ (= SPEC §5 111.3 GB), +MTP = 114 121 223 034 ✓ (= F5 «114.1 GB»); draft URL запинован на коммит 2d9571f8 ✓ | ✓ код согласован с task.md/SPEC/F4/F5 |
| — | **Запреты** | grep по коду (gfctl, lib/, tpl/, tests/, install.sh, README): IP — только generic `0.0.0.0`/`127.0.0.1`; имён хостов/`192.168`/`.ssh`/ключей нет; `.dev/`-доки упоминания машин допускают (blackboard, не код) | ✓ |
| — | **md5 bench-фикстуры (F12)** | `md5sum tpl/bench/merge_sort_thinking_off.txt` | `253c7ac50857fe6d0e10fb0d2c5e35c0` ✓, 140 B |

## Failures (FAIL)

— нет. Все внутренние проверки зелёные.

## Non-blocking notes (не блокируют PASS; передать reviewer/оркестратору)

1. **TYPE_NAMES в `gguf_type_check.py` не канонична вопреки своему комментарию** («Канонический ggml_type enum»): расхождения с ggml.h llama.cpp на 22 (в коде «IQ2_S», канон IQ2_M), 24 («IQ3_XS»/IQ1_M), 25 («IQ1_M»/BF16), 26 («BF16»/legacy-репак), 27–29 (TQ/MXFP4/removed). Таблица task.md тоже не канонична (18–25). **Контракт числовой и совпадает с task.md** (RED = {16,17,18,19,22,25,26} ∪ {t>29}) — на вердикты не влияет, только отображение имён RED/WARN-строк. Рекомендация: выровнять таблицу по ggml.h либо пометить «отображение приближённое» (fix-раунд — одна строка, или бэклог).
2. **Фикстуры используют type 22/23, тогда как test-strategy task.md писала 18/24.** Числово эквивалентно (оба в RED-наборе / оба зелёные), но прямого тест-покрытия членов 18/19 RED-набора фикстурами нет (набор статичен в коде). Дёшево добавить type-18 фикстуру в fix-раунде.
3. **`run_checks.sh` секция 13 зависит от чужого репо**: `cmp` с `/workspace/hfctl/tpl/bench/…` — на машине без hfctl батарея даст ложный FAIL. Заменить на md5-assert `253c7ac5…` (F12) — батарея станет самодостаточной.
4. **Батарея не hermetic по $HOME**: `install.sh` в секции 13 пишет симлинк `~/.local/bin/gfctl` → tmp-каталог; trap удаляет tmp, но не симлинк → dangling-мусор (подтверждено, почищено вручную). Лечится флагом install.sh (например, `GFCTL_NO_SYMLINK=1` для тестов) — 1.2.
5. `download_file` печатает «…part сохранён для докачки» даже когда curl упал до создания `.part` (например, несуществующий URL) — косметика; на реальных HTTP-обрывах `.part` есть.
6. **FACTS F8 внутренне противоречив по flash-шардам**: размеры 00002/00003 (49 604 491 008 / 15 256 783 680) — из НЕгрузящегося IQ4_XS-списка (93.6 GB; сумма с MTP = 96 458 927 994 ≠ заявленным в самой F8 111 334 654 778). Код верен (task.md = SPEC §5 = F5). Оркестратору — дописать F8 (продолжение начатого исправления: 27b-агрегат уже поправлен, размеры шардов — нет).
7. `/workspace/gfctl` ещё не git-репозиторий (коммиты — зона оркестратора при закрытии этапа); `__pycache__` от py_compile удалён при проверке — при коммите добавить `.gitignore` (proposal dev-report).

## External experiments

| EXP-id | DoD-пункт / что доказать живым прогоном | статус |
|---|---|---|
| EXP-001-doctor-evo | doctor/models/status на живой машине ~60 GiB: подсистемы ЕСТЬ (kfd/render/linger/podman), RAM-гейты считают по-настоящему (27b OK ~59.x; flash-multi НЕДОСТАТУПЕН ~59.x vs ≥110), gpu-lock WARN при живом hfctl-проде (D3) | **created** (синтаксис проверен `bash -n`; НЕ исполнялся — hygiene; BLOCKED-EXTERNAL, GO пользователя) |
| EXP-002-dl27b-faex | реальный транспорт HF: pre-flight-строка до трафика, докачка 27b-сета 15 677 391 456 B, sha-PASS ×2, check-types «зелёный», повтор → SKIP ×2 (экономно: flash-сет 111 GB не качать) | **created** (bash -n OK; НЕ исполнялся — hygiene; BLOCKED-EXTERNAL, GO пользователя) |

Скрипты в `.dev/external/`, хосты параметризованы env (GF_ACC_HOST/USER/KEY) —
в репо нет IP/имён машин. Оба EXP belong к приёмке этапа 1 (PLAN) — для DoD
сабстэджа 1.1 внешние проверки не требуются (все пункты brief проверяются
локально и зелёные), поэтому вердикт не BLOCKED-EXTERNAL.

## Regression

- Предыдущие сабстэджи: отсутствуют (1.1 — первый) → регресс = вся батарея
  1.1 + ручные повторы выше.
- `bash tests/run_checks.sh` → **PASS=93 FAIL=0** (дважды, включая повтор
  после очистки артефактов — стабильно).
- Ручные повторы ключевых чеков AGENTS.md и DoD — таблица выше, все зелёные.
- Ошибка-исправление в ходе проверки не требовалась; production-код не менялся.
