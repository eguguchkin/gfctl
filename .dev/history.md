
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
