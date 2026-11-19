
## 2026-11-18 (вечер) — EXP-008/009 gufo: окна пройдены (GO пользователя, монитор 10 с)
- **EXP-008 PASS**: доставка с нуля на FAEX (ai-расклад): uninstall→tar→bootstrap→хардлинки
  (4 файла, пулы ai)→install: RAM-гейт OK, memlock-WARN «достаточно» (F2 в бою), веса SKIP
  (0 трафика), probe 262144 → канон. Инцидент: podman run завис на blob-CDN (0 байт 6+ мин,
  ovh-route мёртв; ghcr и pkg-containers живы) — kill зависшего pull → install retry →
  контейнер поднят. agent-check PASS=4 WARN=0 (сессия 17.4 vs реф 17.2; restore reuse=disk).
  digest-пин снят: gufo-runtime@sha256:99e9b547….
- **EXP-009 PASS (с контингентом)**: ребут FAEX → gfctl-serve падал циклом — root cause:
  **serve-юнит не переносит GFCTL_DIR/GFCTL_MODELS** → gfctl _boot взял дефолты
  ($HOME/gufo + профиль 27b-single) → statfs нет пути. Контингент: Environment= добавлены
  в юнит руками → gufo поднялся сам → verify PASS (health+smoke+device-mismatch нет).
  **DEFECT gfctl (backlog/defect): serve-юнит-tpl должен render Environment=GFCTL_DIR/GFCTL_MODELS**
  (класс дефекта hfctl-этапа 12 — юнит-пути). HFCTL_HEALTH=absent в verify — PATH-нюанс
  скрипта (hfctl в ~/hipfire/hfctl, PATH не включает ~/.local/bin); прод вернут вручную.
- Возврат: gfctl off → hfctl on → HEALTHY 30 с, status ok, linger on. exp-009 fix-r1
  (STACK_DIR gfctl-acc + GFCTL_MODELS в EXP-скрипте) — df8a941.
- EXP-009 хронология монитора (10-с срезы): activating 75×10 с (~12.5 мин) — это НЕ GPU-ожидание,
  а цикл падения дефектного юнита (Environment) до контингент-правки; после правки юнит active
  сразу, gufo healthy (http 200) через ~85 с после старта контейнера; финал — возврат hipfire-прода
  (health_http=000 в срезах — монитор смотрит порт 8080 gufo, корректно). Вывод: без defect-фикса
  (render Environment в юнит-tpl) каждый ребут acc-инсталляции = вечный activating.
- **DEFECT serve-юнит-Environment: ПРИНЯТ ЖИВЫМ РЕБУТОМ (2026-11-19 01:25)**: FAEX ребут с
  gfctl-serve enabled (юнит перерендерен r bc991f1, Environment=GFCTL_DIR/GFCTL_MODELS вшиты) →
  юнит active сразу, gufo поднят юнитом (рук. команд 0), health ok (Loading → ok), journal
  чист от statfs/FATAL/cannot stat (0 вхождений). Финал: gfctl off → hfctl on → HEALTHY 30 с,
  linger on. **DEFECT ЗАКРЫТ.** Попутно: EXP-008/009-инцидент pull-висяка повторно подтвердил
  лечение kill+retry (второй podman run: «incomplete layer deleting» → докачка 2.8 GB → ок).

## 2026-11-19 (ночь) — ФИНАЛЬНАЯ приёмка gfctl из GitHub-клона на FAEX (GO пользователя)
- Полный чистый цикл: uninstall acc → **git clone https://github.com/eguguchkin/gfctl** (2cbb544,
  свежайший) → install.sh → install flash-multi (веса SKIP по хардлинкам, 0 трафика) → healthy
  → **use recreate** (rm+run, «no container» benign ×2 — штатно) → SMOKE OK → **agent-check**.
- Рестарт-restore в agent-check (запланированный) поднял контейнер за 95 с, restore reuse=disk.
- **РЕБУТ**: машина up 25 с; gfctl-serve **active на первом срезе** (юнит с вшитым
  Environment=GFCTL_DIR/GFCTL_MODELS, r bc991f1) — gufo поднят юнитом, рук. команд 0;
  health 200 за ~70 с; **journal чист от statfs/cannot stat/FATAL** → DEFECT ПРИНЯТ ЖИВЬЁМ.
- gfctl smoke 3/3 (роут mtp/2/262144) → gfctl off → hfctl on → hipfire healthy 45 с, linger on.
- Пуш gfctl — сделан пользователем; приёмка шла из GitHub-клона = приёмка запушенного.

## 2026-11-19 (ночь) — EVO-повтер EXP-008/009: ПРОЙДЕН, ЭТАП 4 ЗАКРЫТ (GO пользователя)
- GitHub-клон 2cbb544 на evo → uninstall старой acc → bootstrap → хардлинки (сет 27b: IQ4_XS-pure
  14G + DFlash2 1.1G из acc-models/27b — полный SKIP, 0 трафика весов) → install 27b-single:
  загрузка 95 с → роут mtp/2/262144 → use-recreate (перезапуск) → SMOKE OK → **agent-check**:
  сессия 19.9 s (реф 30.4 — лучше), follow-up 25k 2.9 (реф 3.0), docq 4.0 (реф 3.6) — 3 PASS;
  рестарт-restore упёрся «container name gufo already in use» ×3 (контейнер от recreate жил,
  рестарт-код не сделал rm в этом окружении) — Контингент: podman rm -f gufo вручную →
  контейнер пересоздан (загрузка, health 200).
- **Ребут evo → самоподъём solo**: юнит active (Environment вшит), gufo поднят юнитом,
  health 200 — solo-цикл (запуск/перезапуск/ребут/возобновление) ПРОЙДЕН.
- **27b-multi**: use 27b-multi → роут dflash2/sessions 2/ctx 196608 (канон EXP-006) → SMOKE OK
  → перезапуск (use повторно) SMOKE OK → **ребут** → самоподъём multi (gufo Up 10 мин,
  health ok) → возобновление OK.
- Финал: gfctl off → hfctl on → hipfire healthy 30 с (27b-single mq4), linger on.
- Монитор-артефакт: после ребута 10 мин «ssh-warming» в параллельном мониторе при живом
  сервере (конкурентные ssh-сессии после ребута) — не состояние сервера, зафиксировано.
- **ЭТАП 4 gfctl: ЗАКРЫТ** (доставка из GitHub-клона, ребут-приёмки обеих flavor, evo+FAEX;
  defect юнит-Environment закрыт с живой приёмкой).
- Урок evo-цикла (для EXP-хвостов): `gfctl up` при живом hfctl-проде = RAM/GPU-конфликт
  (gufo multi 2×196608 потребовал 29+ GiB device при 21.7 доступных из-за прод mq4) →
  load_failed + юнит циклит рестарты 30-с циклом. Обязательный порядок: **hfctl off →
  gfctl up → … → gfctl off → hfctl on** (EXP-008 PREREQ это фиксирует — соблюдал
  FAEX, нарушил на evo-финале — выправлено в окне). Юнит-зомби gfctl-serve active(exited)
  после gfctl off при не-vоid daemon-reload — безвреден, исчезает при ребуте.
