# Test report: 5.1-parity-preflight

Verdict: **PASS** (внутренние зелёные; external отложены по brief/DoD — окно этапа 5, два GO по D6; EXP-013 DEFERRED по D8)

- Дата: 2026-11-21 / проверка по dev-report fix round 1
- Проверено независимо (не по отчётам): код прочитан, батарея прогнана дважды,
  hfctl-канон сверен построчно, slirp-скоуп проверен ручной пробой на свежем
  стеке, EXP-скрипты прочитаны + bash -n, отсутствие result-файлов констатировано.

## Internal checks

| DoD | Проверка | Результат |
|---|---|---|
| 1 apt-пятёрка | Код `preflight_host` (lib/commands.sh:433–502): need-список пятёрки, ОДИН `sudo apt-get update -qq && sudo apt-get install -y -qq $need` ТОЛЬКО при непустом need; нет sudo/apt-get → die с ручным рецептом (rc 1); apt-сбой → die с рецептом. Батарея: T1 (ровно пара update→install с полным списком), T2 (**apt 0 раз при «всё на месте»** — идемпотентность), T3 (FATAL+рецепт, rc 1, не тихий skip), T4 (apt-сбой → rc 1, поток не продолжен) | ЗЕЛЁНО |
| 2 GPU-prep | Гейт `${GFCTL_KFD:-/dev/kfd}`\|`${GFCTL_DRI:-/dev/dri}`; `id -nG` на обе группы; usermod + «группы применятся только после перезахода…» + **exit 42**; обе есть → no-op без sudo; нет GPU → одна info-строка «GPU-подготовка пропущена». limits.d НЕ дублируется: GPU-prep файл не пишет, единственный владелец `99-gfctl-memlock.conf` — memlock-гейт (тексты и коды сверены с HEAD **байт-в-байт**: строки 460/464/467 HEAD ↔ 492/496/499 new; RAM-gate die-тексты идентичны). Батарея T5/T6/T7 (T6 подтверждает порядок: GPU-prep раньше apt — apt/limits не достигнуты при rc 42) | ЗЕЛЁНО |
| 3 Slirp-скоуп | tpl/containers/gfctl-containers.conf = канон EXP-013 **посимвольно** (комментарий + `[network] default_rootless_network_cmd = "slirp4netns"`). Bootstrap: cmp-гвард + install 0644. Export: `if [ -f ]`-гвард (set -e-безопасный) в верхнеуровневом скоупе диспетчера, **до source lib и роутера** → покрыты `_boot`/`_watchdog` (юниты зовут `bash …gfctl _boot`). **Ручная проба** (свежий $TMP-стек): файл создан, байты=tpl; повторный запуск — mtime не изменился (cmp-гвард идемпотентен); tpl удалён → файл не создаётся, в родительском shell env чист (export только внутри процесса gfctl — hfctl env не получает). Батарея T9 (frun-процесс: `env CONTAINERS_CONF=…` в журнале faux-podman), T10 (а)(б)(в), T11 (в юнитах/tpl CONTAINERS_CONF нет) | ЗЕЛЁНО |
| 4 Orphan-heal mirror | Построчная сверка `gf_orphan_heal` (lib/serve.sh) с `hf_orphan_heal` (/workspace/hfctl/lib/autostart.sh:318–334): **1:1** — сигнатура `already in use by [0-9a-f]{12,64}` с глушеным grep; гард 1 кап `[ GF_ORPHAN_HEALS -lt HEAL_MAX ]`; гард 2 бинаря нет → WARN + ручной рецепт (текст идентичен); гард 3 `podman inspect` успешен → «видит libpod — не сирота» (текст идентичен); инкремент до delete-container (как в hfctl); гард 4 delete-container отказал → WARN (текст идентичен); log успеха идентичен. Call-site: вызов при отказе run (контейнер ≠ running) ДО следующей попытки = паттерн hfctl (autostart.sh:426/488: heal при ≠running → один retry). Die при исчерпании попыток **дополнен ручным рецептом** сироты. hfctl не тронут (только чтение). Батарея §21b T14 (delete-container ровно 1, ровно 2 run, rc 0), T15 (живой ID не тронут), T16 (Variant-B: WARN+рецепт, retry как прежде), T17 (кап HEAL_MAX=1; die содержит рецепт), T18 (happy-path: хил-ветка 0 раз) | ЗЕЛЁНО |
| 5 EXP-скрипты И2 | Все три созданы в .dev/external/, **НЕ запущены** (result-файлов EXP-013/014/015 нет — проверено ls; D6 соблюдён). EXP-013: `STATUS: DEFERRED (D8)` в шапке, REPO_URL=github.com/eguguchkin/gfctl, git clone/pull --ff-only (И3/F21), tar/cp запрещены в пререквизитах, фазы PHASE=1/2/3 + пролог перелогина. EXP-014: git pull обоих клонов, диагностические ЧТЕНИЯ, linger-восстановление **жёстким ассертом** `[ "$LING" = "yes" ]` (F11), пролог перелогина (п.4 Round 2). EXP-015: (а) pgrep slirp>0 / pasta не растёт, (б) «kill network process»=0 в on+recreate+journalctl, (в) graphRoot с env и без идентичен (fail при расхождении), (г) обратный hfctl on /ready + linger=yes. Все: bash -n зелёный, финальные `RESULT: PASS\|FAIL\|ERROR` на всех ветках | ЗЕЛЁНО |
| 6 Батарея | `bash tests/run_checks.sh` — **два прогона: PASS=400 FAIL=0, rc=0 оба** (стабильно; 381 базлайн + 19 новых). Секции §17c (T1–T12) и §21b (T14–T18) в логе; §17b memlock-блок не тронут (git diff — только комментарии-ссылки); `bash -n gfctl lib/*.sh` OK; `bash -n tests/run_checks.sh` OK; `python3 -m py_compile tpl/python/*.py` OK | ЗЕЛЁНО |
| 7 SPEC honesty | .dev/SPEC.md: §2 — абзац «Первичная установка — preflight хоста (5.1, И1)», gitignore-строка, исключения «вне каталога» пополнены (группы, apt-пятёрка); §3 — строки install/use (preflight_host с полным порядком) и doctor (пакеты/группы/slirp/graphRoot); «Соответствие gfctl (ревизия 2026-11-21)»: И1 **«по коду полное»** с честной оговоркой «bare-приёмка отложена (D8), EXP-013 deferred, живьём не подтверждён до окна»; И2 расширено (rm-в-попытке + gf_orphan_heal); чек-лист «Этап 5» — кодовые пункты [x] с приёмочными открытыми (окно). `spec_validate` → **valid**. AGENTS.md bootstrap-абзац обновлён («+ ставит .gfctl-containers.conf (скоуп slirp4netns, export CONTAINERS_CONF — этап 5.1; юниты НЕ ставит)»). DECISIONS D8 ратифицирован | ЗЕЛЁНО |
| Гейты AGENTS | `./gfctl` без аргументов → usage, **rc=1**; неизвестная команда → rc=1 + список команд (рецепт в сообщении); `GFCTL_PORT=8198 ./gfctl status --json` → rc=0, корректный отказ `«health":"не запущен"`, не краш | ЗЕЛЁНО |

## Failures (FAIL)

Нет.

## External experiments

| EXP-id | DoD | Статус |
|---|---|---|
| EXP-013-gfctl-parity-bare | DoD 1/2 живьём (bare-Ubuntu apt+GPU+перезаход+ребут-приём) | **created / DEFERRED** (D8: ресурс не выделен; заготовка на будущее окно) |
| EXP-014-gfctl-off-hfctl-on | DoD 3/5 (последовательность + linger F11) | created / **ответа нет** — окно этапа 5, два GO по D6 |
| EXP-015-hfctl-off-gfctl-on | DoD 3/4/5 (slirp-ассерты (а)–(г), обратная последовательность) | created / **ответа нет** — окно этапа 5, два GO по D6 |

Новых EXP не требуется. Verdict PASS с пометкой: живая приёмка (EXP-014/015 +
хвосты EXP-010/011/012 + ребут/рестарт-приёмы fix-r2) — окно этапа 5 по D6;
EXP-013 — deferred (D8).

## Regression

- Полная батарея дважды: **PASS=400 FAIL=0, rc 0** — все закрытые подэтапы
  зелёные, включая §17 install happy-path, §17b memlock (байт-в-байт), §18 use
  (с шимами новых гейтов, ассерты не ослаблены), §20 boot/watchdog, §21
  recreate-ретрай, §37 watch v2, §38 README, §40 install-идемпотентность,
  §41 uninstall, §43 install-probe.
- git-дельта 5.1 = ровно таблица диффа task.md: `gfctl`, `lib/commands.sh`,
  `lib/serve.sh`, `tpl/containers/gfctl-containers.conf` (NEW), `.gitignore`,
  `tests/run_checks.sh`, `.dev/SPEC.md`, `AGENTS.md`, EXP-013/014/015 (NEW).
  Watch-файлы (tpl/python/watch_*.py, fixtures, EXP-012) принадлежат дельте
  закрытой 4.5-watch-v2 (её dev-report; рабочее дерево не коммитилось —
  накопленный diff vs HEAD), кодом 5.1 не тронуты; §37 зелёный в обоих
  прогонах. DECISIONS/STATE/history — ведение оркестратора (D8).
- Ошибки несут рецепт действия: die apt/sudo — список пакетов; die сироты —
  `containers-storage delete-container <ID>`; gpu-lock WARN — «hfctl off /
  gfctl off»; memlock — «ПЕРЕЛОГИНЬСЯ»; GPU-группы — «выйди и зайди».

## Оценка отклонений developer (все задокументированы в dev-report)

1. **T11 через gf-харнесс вместо frun use** — обоснование проверено:
   `gpu_nodes_present` не имеет env-хука (Design §3 — намеренно), dispatcher
   в ocbox умирает на железном гейте до рендера юнитов. Уникальная ценность
   T11 (юниты не разрослись `Environment=CONTAINERS_CONF`; ExecStart=bash…gfctl
   _boot) ассертится полностью; процессный путь экспорта покрыт T9/T10 через
   frun (env-строка в журнале faux-podman — именно процессная доставка).
   **Покрытие эквивалентно — принято.**
2. **stderr-диагностика при несработавшем хиле** (`printf '%s\n' "$run_out"
   >&2`) — это печать вывода попытки, не ручная команда и не рецепт-требование
   (И2 запрещает ручные мутации, а не диагностику); зеркалит поведение call-site
   hfctl (печать out|tail -2). Побочный эффект — ID успешного run больше не
   печатается в stdout: потребители stdout container_up проверены (все 5
   call-site'ов — чёрный ящик с die при неудаче; роут/health печатаются
   отдельно), §20/§21 зелёные. **Конфликта нет — принято.**
3. **faux-счётчик 7→11** — ассерт обновлён на строгие 11 с полным списком
   заглушек (podman/systemctl/loginctl/sudo/curl/stat/sleep/id/usermod/
   podman-compose/containers-storage) — адаптация к новым мокам, не ослабление;
   задокументирован в dev-report. **Принято.**
4. Неблокирующая заметка: формулировка Round-2 в task.md «успех → log-строка +
   счётчик» vs код (инкремент ДО delete-container) — код 1:1 с hfctl, что и
   есть ратифицированная директива («Перенос … 1:1 со ВСЕМИ гвардиями»);
   неточность буквы буллета, не кода.

## Скоуп-заметки тестера

- Прогоны батареи и ручная проба создали gitignored-артефакты bootstrap в
  dev-клоне (.data/, .gfctl-containers.conf) — штатное поведение любого вызова
  ./gfctl, вне гит-стата. Коммитов нет, STATE.md/код не правились,
  hfctl/llm-lab — только чтение, наружу ssh/podman не было.
