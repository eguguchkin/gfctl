# Test report: 1.2 жизненный цикл — serve-юниты + install/use/on/off/uninstall + smoke/logs + watchdog/boot

Verdict: **PASS**
Tester: 2026-11-17 · прогон полный, самостоятельно (не по чек-листу developer);
внешние EXP не исполнялись (hygiene), EXP-003 поставлен в очередь.

## Internal checks

### 1. Батарея `bash tests/run_checks.sh` — 5 прогонов подряд (стабильность)

| прогон | результат |
|---|---|
| 1–5 | каждый: **PASS=180 FAIL=0, rc 0** (~5 с) — стабильно |

Разбор батареи по секциям (счёт PASS из живого прогона; 95 «старых» в §1–13 +
85 «новых» в §14–25 и шапке faux-bin = 180):

| секция | PASS | что проверяет |
|---|---|---|
| шапка | 1 | **faux-bin**: 6 PATH-заглушек (podman/systemctl/loginctl/sudo/curl/sleep), каждая пишет «<cmd> <args>» в `$GFCTL_FAUX_LOG`, сценарии через `GFCTL_FAUX_*` (run-fail-N, inspect=state, is-enabled, curl /ready+chat JSON, sleep мгновенный) — ни одного реального podman/systemd/sudo-вызова |
| 1 | 2 | AGENTS internal: `bash -n gfctl lib/*.sh`, `py_compile tpl/python/*.py` |
| 2 | 16 | диспетчер: bare→rc1+usage; garbage→rc1+список+Профили; `--help`→rc0; **заглушки сняты ровно по п.0**: install — не-заглушка (die по грамматике), watch/bench/cache/agent-check → rc1 «этап», use/logs/on/off/up/down/uninstall/smoke — «не-заглушка» (процессный прогон <30 c без «появится в сабстэдже») |
| 3–11, 13 | 38 | регресс-база 1.1 (см. «Regression») |
| 12 | 3 | `status --json` мёртвый порт: json.tool парсит; схема 1.1 (health/route/autostart/version null + gates + models) **+ cache:null** (п.0-замещение); человекострока живого формата |
| 14 | 8 | **state**: write_canon байт-в-байт = env.tpl с подстановкой; canon_get приоритет env > .env > default; кривой GFCTL_PROFILE → дефолт; overrides sessions/context в каноне |
| 15 | 5 | **serve_args**: канон 27b-single байт-в-байт Design; чистота (2 вызова идентичны); multi (draft-путь, оверрайды); flash (--model = первый шард 00001 + --mtp-model); чужой токен @BOGUS@ → die |
| 16 | 2 | **render_tpl**: подстановка `__X__`; чужой плейсхолдер → die rc 1 |
| 17 | 14 | **install happy-path**: строка `podman run` в faux-логе байт-в-байт = канону Design (F9-флаги, маунт каталога-сета, serve-строка); 3 юнита в systemd-user c контент-грепами (ExecStart=`_boot`, KillMode=process, TimeoutStartSec=900, ExecStop=rm -f, `_watchdog`, OnUnitActiveSec=1min); enable-linger; маркер снят; **порядок recreate→health→smoke** (индексы в логе rm < run < logs < /ready < chat); веса-SKIP; идемпотентный повтор (run +1, юнитов по-прежнему 3) |
| 18 | 8 | **use**: die на неизвестном профиле и `--sessions abc`; happy-path (SMOKE OK, канон перезаписан, run c оверрайдами, @DRAFT@→/models/<draft>, автозапуск НЕ тронут); `--no-probe` → WARN no-op rc 0 |
| 19 | 7 | **health**: parse_route «последняя load_completed побеждает» (4 поля), пустой лог → пустые ROUTE_*; wait_load rc0 + «загрузка завершена»; wait_health + строка «роут: dflash2, sessions 1, ctx 262144»; таймаут без load_completed → rc1 + хвост логов; **load_failed ранний выход** (seam GFCTL_LOADFAIL_AFTER); /ready отказ → rc1 без роут-строки |
| 20 | 18 | **маркер-раньше-подъёма**: boot без GPU-нод → rc1; нода со 2-й проверки → ровно 1 run rc0; `_watchdog` с маркером → **ПЕРВАЯ проверка, ноль podman-вызовов** rc0; без .env → return 0; exited без маркера → ровно 1 run + событие в logs/watchdog.log; **off**: touch-маркер РАНЬШЕ podman rm и systemctl disable, юниты удалены, disable-linger, rc0; **on**: enable serve+timer, маркер снят, юниты восстановлены, smoke НЕ зовётся (0 chat); **up**: маркер снят + 1 run + health, автозапуск не тронут |
| 21 | 2 | **ретрай порта (F10)**: 1-й run упал → ровно 2 вызова run rc0; все GFCTL_RUN_ATTEMPTS неудачны → die rc1, вызовов = attempts |
| 22 | 3 | **logs**: `logs 50 -f` → `podman logs -f --tail 50 gufo`; missing-контейнер → die rc1 «контейнера нет» |
| 23 | 5 | **smoke**: happy → SMOKE: OK, ровно 3 curl; **ретрай РОВНО первого (F15)**: FAILFIRST → 2+1+1 = 4 вызова + WARN, rc0; FAILALL → rc1 |
| 24 | 10 | **uninstall-слои**: GFCTL_YES → rc0; **веса на месте, `podman rmi` ОТСУТСТВУЕТ**; дерево снесено кроме models; слой limits.d (sudo rm); linger off; юниты удалены; `--purge-models --purge-image` → веса удалены + rmi в логе; без согласия (не-TTY) → rc1 и ничего не удалено |
| 25 | 2 | **живой status**: человекострока `профиль: … \| health: ok \| автозапуск: вкл \| роут: dflash2, sessions 1, ctx 262144 \| кэш: …(N.N GiB) \| веса 27b: 2/2` (реальный слушатель 127.0.0.1:8080 на python-stdlib, гасится по завершении); `--json` живой: route{speculative,sessions,context,model}/autostart/version/cache + **старые ключи и типы 1.1 на месте** |

### 2. Ручные повторы ключевых чеков (мои команды, не батарея)

| чек | команда | результат |
|---|---|---|
| lint bash | `bash -n gfctl lib/*.sh` | rc 0 |
| lint python | `python3 -m py_compile tpl/python/*.py` | rc 0 |
| bare | `./gfctl` | rc 1 + usage (шапка «gfctl — деплой…», «Команды:») |
| garbage | `./gfctl zzz` | rc 1 + «неизвестная команда… Профили: 27b-single 27b-multi flash-multi» |
| заглушки 2–3 ровно | `./gfctl watch|bench|cache|agent-check` | каждая rc 1 «команда 'X' — этап 2/3»; у install/use/logs/on/off/up/down/uninstall/smoke заглушек нет (роутер `gfctl:195–204`, секция 2 батареи) |
| down = off | процессный прогон с faux-PATH: `./gfctl down` | rc 0; маркер `.gfctl-stopped` создан; `podman rm` → linger off (порядок touch<rm<disable точечно ловит секция 20 батареи); вывод «ВЫКЛ… Вернуть: gfctl on» |
| up = канон | `./gfctl up` после use-канона | rc 0; маркер снят; ровно один `podman run` c канонической serve-строкой (в моём прогоне — значения таблицы 27b-single при пустом .env: canon_* корректно падают в таблицу); «роут: dflash2, sessions 1, ctx 262144» |
| status --json мёртвый порт | `GFCTL_PORT=8198 ./gfctl status --json` | rc 0, json.tool валиден; route/autostart/version/cache = null |
| doctor без GPU/podman | `./gfctl doctor` в dev-контейнере | rc 0, без traceback/FATAL; деградация «?»/WARN по всем секциям, RAM-гейты цифрами (31.3 < 56/110 → НЕДОСТАТУПЕН) |
| «отказ как надо» | `./gfctl use 27b-single` в контейнере (31 GiB RAM) | die rc 1 с цифрами и рецептом: «RAM-гейт: 27b-single: ≥56 GiB — есть 31.3: НЕДОСТАТУПЕН — отказ ДО трафика» |
| check-types фикстуры 1.1 | `gguf_type_check.py` на tests/fixtures | IQ2_S(ffn)→rc 1, IQ4_XS(ffn)→rc 0, не-GGUF→rc 2 |
| пины весов 1.1 | weights_for ×7 | все 7 sha — полные 64-hex; суммы: 27b = 15 677 391 456 B; flash-шарды = 111 334 654 778 B (114 121 223 034 − MTP 2 786 568 256) |

### 3. DoD brief 1.2 — по пунктам

| # | item (brief) | результат | доказательство |
|---|---|---|---|
| 1 | install/use/on/off/uninstall/logs/smoke/_watchdog реализованы; заглушки сняты ровно у них | **met** | роутер gfctl:195–204 (+скрытые up/down/_boot); секция 2 батареи (16 PASS); каждый cmd_* имеет батарею (§17/18/20/22/23/24) |
| 2 | tpl-юниты (serve oneshot+RemainAfterExit+KillMode=process, watchdog timer 1 мин, env-шаблон) генерируются с подстановкой маркеров | **met** | tpl-файлы прочитаны (Type=oneshot, RemainAfterExit=yes, KillMode=process, TimeoutStartSec=900, Restart=on-failure/30; OnUnitActiveSec=1min); §16 render_tpl+die; §17: 3 юнита в `$HOME/.config/systemd/user` c контент-грепами, env.tpl байт-в-байт (§14) |
| 3 | serve-строка из профильной таблицы (@DRAFT@/@MTP@ → /models/…) | **met** | serve_args (serve.sh:34–54): поле 7 с подстановкой, неизвестный токен → die; §15 канон байт-в-байт; §17 podman run байт-в-байт; flash = первый шард 00001 + @MTP@ |
| 4 | health-предикат (таймаут, парсинг load_completed, ретрай первого 15 с) | **met** | wait_load таймаут 180 (progress-печать, load_failed-ранний выход с seam 20 c), parse_route (последняя побеждает), http /ready + 30-с поллинг; smoke-ретрай ровно первого `GFCTL_SMOKE_RETRY_S:-15`; §19/§23 |
| 5 | порядок recreate→health→smoke | **met** | cmd_install/cmd_use: container_up → wait_health 180 → smoke (commands.sh:400–403, 456–458); §17 индексы rm < run < logs < /ready < chat; §18 для use |
| 6 | off → вотчдог НЕ воскрешает; on возвращает всё | **met** | cmd_watchdog: маркер — первая строка (autostart.sh:132), §20 «ноль podman-вызовов»; off: touch ДО rm/disable, юниты сняты, linger off; on: enable+timer+linger+подъём, маркер снят |
| 7 | uninstall без флагов оставляет модели+образ | **met** | §24: веса на месте, rmi отсутствует, стек снесён кроме models; согласие обязательно (не-TTY → rc1, ничего не удалено) |
| 8 | status --json расширен без ломания схемы 1.1 (null'ы мёртвого порта) | **met** | §12 (мёртвый порт: старые ключи/типы + cache:null) и §25 (живой: route/autostart/version/cache заполняются, старая схема на месте); ручной json.tool |
| 9 | Internal checks зелёные; регресс 1.1 не сломан | **met** | 5×PASS=180 FAIL=0; см. «Regression» |

Замечания к DoD (не блокируют): `cmd_use` не перерендеривает юниты —
задокументировано developer'ом (serve-строка собирается из канона в момент
container_up/_boot, юниты профильных данных не содержат; §17 подтверждает
юниты без профильных маркеров); SPEC §4 уже синхронизирован с фактическим
форматом человекостроки (по состоянию на этот прогон — норма).

### 4. F-факты в коде

| факт | где | подтверждение |
|---|---|---|
| F2 `--host 0.0.0.0` | serve.sh:52 — печатается всегда, первым в serve_args | §15/§17 байт-в-байт канон |
| F9 podman-флаги ровно | serve.sh:140–147: `--device /dev/kfd --device /dev/dri --group-add keep-groups --ipc=host --ulimit memlock=-1:-1 --userns=keep-id:uid=1000,gid=1000` | §17 run-строка байт-в-байт |
| F10 пауза/ретрай после rm | serve.sh:131 rm-f, :135 `sleep GFCTL_RECREATE_PAUSE_S` (дефолт 3), :150 `sleep 5` между попытками, до GFCTL_RUN_ATTEMPTS (дефолт 3) | §21 |
| F11 linger off только в off/uninstall | grep disable-linger: ровно autostart.sh:109 (cmd_off) и commands.sh:558 (cmd_uninstall); install/use/on/up/watchdog/boot linger не снимают | §20/§24 |
| F15 ретрай первого | health.sh:166–169, дефолт 15 с | §23 (2+1+1=4 вызова) |
| F16 маркер первой проверкой | autostart.sh:132 — первый statement cmd_watchdog | §20 (ноль podman-вызовов при маркере) |

### 5. Запреты и гигиена

- **IP/имена хостов/ключи**: grep по репо (вкл. .dev/external, искл. .git) —
  0 совпадений вне разрешённых loopback 127.0.0.1/0.0.0.0; EXP-001/002/003
  параметризованы GF_ACC_HOST/USER/KEY.
- **bench-фикстура md5** = `253c7ac50857fe6d0e10fb0d2c5e35c0` ✓ (не редактировалась).
- Роль ничего не исполняла наружу: faux-bin только в $TMP батарея/мои прогоны;
  слушатель §25 — 127.0.0.1:8080, гасится; артефакты моих прогонов убраны
  (dangling `~/.local/bin/gfctl` от §13 — известный backlog 1.1 note#4 —
  удалён, `__pycache__` убран).

## Failures (FAIL)

— нет. Ни одного FAIL ни в 5 прогонах батареи, ни в ручных чеках.

Наблюдения вне вердикта (backlog, не блокирует — оба никогда не дают
ложный PASS):
1. Секция 13 батареи по-прежнему `cmp` с `/workspace/hfctl/tpl/bench/…`
   (1.1 review note#3: на машине без hfctl — ложный FAIL; «можно в 1.2» —
   не сделано). md5-контроль фикстуры я выполнил вручную (см. выше).
2. Секция 13 не герметична по $HOME (симлинк в реальный ~/.local/bin) —
   1.1 review note#4; артефакт почистил.

## External experiments

| EXP-id | DoD item | статус |
|---|---|---|
| EXP-001-doctor-evo | гейты/doctor/status на живой ~60 GiB | created (ранее), ответа нет |
| EXP-002-dl27b-faex | реальный транспорт HF + sha256 ×2 | created (ранее), ответа нет |
| **EXP-003-life-evo** (создан этим прогоном) | полный жизненный цикл на живой машине: install (или use при скачанных весах) → healthy («роут: dflash2, sessions 1, ctx 262144») → smoke → off → вотчдог 70 c + явный `_watchdog` не воскрешает → on → recreate+health; PREREQ: GO пользователя, GF_ACC_HOST/USER/KEY, hfctl-прод остановлен/возвращён оператором окна | created, **не исполнялся** (BLOCKED-EXTERNAL, приёмка этапа 1) |

## Regression

- **Батарея целиком**: 6 прогонов (5 стабильность + 1 с фиксацией по секциям)
  — PASS=180 FAIL=0 rc 0.
- **Секции 1.1 (§1–13)**: зелёные; §2/§12 замещены ровно по п.0 Test strategy
  task.md (заглушки остаются только у watch/bench/cache/agent-check;
  человекострока — живой формат + cache:null в схеме), остальные нетронуты.
  git-истории в /workspace/gfctl нет («not a git repository») — нетронутость
  §3–11,13 сверена по содержимому файла против описаний в dev-report 1.2 и
  review 1.1 (фикстуры байт-в-байт, RED-контракт, 27 полей таблицы, таблицы
  весов и суммы, инвентарь, download_file, согласие download, doctor,
  install.sh: раскладка/повтор/отказ вне дерева).
- **Ручные повторы контрактов 1.1**: check-types фикстуры (IQ2_S→RED rc1,
  IQ4_XS→rc0, не-GGUF→rc2); doctor без GPU/podman rc0 без краша; пины
  7×64-hex, суммы 15 677 391 456 / 111 334 654 778; bare/garbage rc1;
  status --json мёртвый порт валиден — все зелёные.
