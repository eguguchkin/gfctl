# FACTS gfctl — проверенные факты (исправляются только реальными прогонами)

## F1 · Инсталлятор моделей в релизном образе gufo отсутствует
Команда `gufo model` есть только в HEAD репо; релизный образ 0.34.0+
(`ghcr.io/gufo-org/toolboxes/gufo-runtime`) её не содержит — веса качает
gfctl (окно G-P3, 2026-11-15, evo).sha-пины — из `src/models/*/models.lock.json`.

## F2 · gufo serve в контейнере обязан слушать 0.0.0.0
Дефолт `--host 127.0.0.1` внутри контейнера = port-publish мёртв
(`event=listening address=http://127.0.0.1:8080`, curl с хоста rc=56/000).
Обязательно `--host 0.0.0.0` (окна IX 2026-11-17, доки cli.md §`--host`).

## F3 · unsloth UD-* GGUF не загружаются gufo
UD-IQ4_XS 27B: `Unsupported projection tensor type for blk.0.ffn_gate.weight:
IQ2_XS` (окно IX); UD-IQ4_XS flash-next: `unsupported storage type:
blk.8.ffn_down_exps.weight` (окно FX). Pre-check по GGUF-заголовку
(`gguf_type_check.py`, без GPU) корректно предсказывает отказ.

## F4 · pure-IQ4_XS 27B (jpetrina) загружается и быстрее K-quant
`qwen3.8-27b-IQ4_XS-pure.gguf` 14,534,384,640 B, sha256
`ea5a3c45d407f9b9e5d2c0d647f0ea600f486f6b86b92b56d0823ba073dae675`.
gpu_device_used 45.9 GiB (sessions 1×262144) / 49.0 (2×131072) из 124.
Фикстура 253c7ac5: 76.9 t/s (draft 98.5%). Окно IX 2026-11-17, evo.

## F5 · flash UD-Q4_K_XL загружается; память
Веса+MTP 114.1 GB; sessions 1×262144: device 96 GiB из 124, host_available
28.7 GiB, load ~94 с. sessions 2×131072: device 98.5 GiB, host 28.4 GiB.
sessions 4×65536: device 99.0 GiB. Окно FX 2026-11-17, FAEX (MemTotal 122 GiB).

## F6 · flash-multi проверенные точки (floor и выше)
2×131072: агрегат 56.1 tok/s (2×600); 4×65536: агрегат 77.3 (4×600).
2×262144 НЕ испытан — probe-цель gfctl (этап 2). Окно FX.

## F7 · 27b-multi 2×163840 проверен (Q4_K_XL, окно G8–G12)
Влезает с живым кэшем (движок сам урезал RAM-cache), агрегат 2-пар 29.5.
196608 — «впритык» на Q4_K_XL; IQ4_XS легче на 3.9 GiB → запас больше.

## F8 · Веса и sha256 (пины для models-модуля; полные 64-hex — tasks/1/1.1/task.md §models)
- 27B сет (сумма пинов 15,677,391,456 B): `qwen3.8-27b-IQ4_XS-pure.gguf`
  (jpetrina) 14,534,384,640 B sha `ea5a3c45…e675` + draft
  `Qwen3.8-27B-DFlash2-Q4_K_M.gguf` 1,143,006,816 B sha `1a25c568…1ebd`
  (репо `z-lab/Qwen3.8-27B-DFlash2-GGUF`, пин на коммит 2d9571f8).
- flash сет (UD-Q4_K_XL, 111,334,654,778 B суммарно): шарды 00001..00004
  (10946618 / 49720539552 / 32803030176 / 28800138432 B; sha `acc44040…`,
  `45792ae8…`, `8c76e79d…`, `5de8b5db…`) + `MTP/mtp-…-shared-Q8_0.gguf`
  2,786,568,256 B sha `5ff54097…` (репо `unsloth/Qwen3.8-Flash-Next-GGUF`,
  resolve/main; sha-пин ловит дрейф ревизии). Сумма с MTP = 114,121,223,034 B.
- Источник полных значений: dl-скрипты окон IX/FX (sha-verify PASS).
  ⚠️ Файлы unsloth UD-IQ4_XS (93.6 GB) к профилю gfctl НЕ относятся
  (не грузятся, F3).

## F9 · Обязательные podman-флаги gufo (rootless, evo/FAEX)
`--device /dev/kfd --device /dev/dri --group-add keep-groups --ipc=host
--ulimit memlock=-1:-1 --userns=keep-id:uid=1000,gid=1000`; юзер hipfire
uid=1001. Без userns на этих машинах окна не проверялись — включать как в
проверенных запусках.

## F10 · Rootless podman медленно освобождает порт после rm -f
Между recreate-конфигами — пауза/пауза-ретрай (окна G/H; hfctl-грабля та же).

## F11 · hfctl off снимает linger; user manager умирает через ~10 с
В окнах: после `hfctl off` — немедленный повторный `loginctl enable-linger`.
Для gfctl off/off-семантики: linger off только в явном `off`.

## F12 · Bench-фикстура merge_sort: md5 253c7ac5
Канон `tpl/bench/merge_sort_thinking_off.txt`; правка байтов меняет хеш и
сравнимость. Единственный честный A/B; `bench quick` hfctl — другой сценарий.

## F13 · gufo отказ 2×262144 на 27B (admission)
«2 sessions leave 0 MiB for the RAM cache above the 4096 MiB host reserve
(21444 MiB requested)» — documented refusal; лестница 27b-multi начинается
с 196608.

## F14 · Машины: RAM-пул и device
evo: MemTotal 62,353,152 kB (~59.5 GiB pool); FAEX: 122 GiB, device_total
126,976 MiB (~124 GiB). flash-single требует ≥110 GiB RAM (гейт gfctl).

## F15 · Смоук-ретрай через 15 с
Окно прогрева ядер после ready: первый запрос может быть 5xx/медленный
(hfctl-опыт этапа 9) — smoke делает один ретрай.

## F17 · EXP-приёмка этапа 1 на живом evo — PASS ×3 (окно 2026-11-17)
EXP-001 (doctor/models/status): гейты цифрами на живом железе (27b OK
59.5 GiB, flash НЕДОСТУПЕН), JSON валиден. EXP-002 (download): реальный
HF-транспорт, оба файла sha OK (пины F8 подтверждены), check-types на
живом pure-IQ4_XS зелёный (v3, 866 тензоров), идемпотентность SKIP.
EXP-003 (жизненный цикл): use → гейт → загрузка движка **15 с** (тёплая
машина) → роут dflash2/1/262144 → SMOKE 3/3 → off (маркер+юниты+Linger=no)
→ вотчдог 70 с молчит + явный _watchdog уважает маркер (F16 живьём) → on
(recreate, symlinks, linger=yes) → health ok. Восстановление hfctl-прода:
gfctl off → hfctl on HEALTHY 15 с → smoke OK.
- load_failed-порог 20 с НЕ наблюдался живьём (load_failed не случился) —
  остаётся design-константой.
- ⚠️ rsync в ocbox отсутствует: EXP-транспорт = tar|ssh (правка 2026-11-17,
  все три EXP).

## F20 · flash-multi на FAEX — каноны probe и bench (EXP-005 финал, 2026-11-17)
- **2 сессии: 262144 влезает — МАКСИМУМ лестницы** (явная попытка + probe
  согласны): load 95–100 c, gpu 105.4/127 GiB, host 21.5–21.7 GiB, роут
  `mtp draft_limit 7`, SMOKE 3/3. БЕНЧ медиана **88.5 tok/s** (155 ток,
  ×3: 88.5/78.1/88.6) — выше соло-референса FX (85.8) и 27b (76.9).
- **4 сессии: 196608 канон** (лестница: 262144 таймаут 180 c; 229376
  живой admission-отказ с цифрами «4 sessions leave 0 MiB for the RAM
  cache above the 4096 MiB host reserve» — формат F13 подтверждён;
  196608 загрузка 95 c). БЕНЧ медиана **88.1 tok/s**. Пар (flash-multi,4)
  и (flash-multi,2) — изолированные каноны в .env ✅.
- check-types: UD-IQ4_XS КРАСНЫЙ на 00002/00003 (ffn-тензоры там);
  00001 (0 тензоров) и 00004 (1 тензор) ffn не содержат → зелёные
  корректно. q4xl+MTP 5/5 зелёные. indexer-тензоры type 30 (BF16) вне
  ffn — только информационные WARN (движок грузит их нормально).
- Формальные FAIL первого завершённого прогона — ошибки критериев
  EXP-005 (SKIP ровно 5 vs накопление 20; «КРАСНЫЙ на КАЖДОМ» vs
  физика шардов) — критерии исправлены post-hoc (без перезапуска окна).

## F19 · Симлинки весов не видны в контейнере через bind-маунт (FAEX, 2026-11-17)
`~/gfctl-acc-models/flash/` с СИМЛИНКАМИ на `~/gufo-models/...`: podman
маунтит каталог, но цели симлинков вне маунта → движок: `cannot open
/models/…: No such file or directory`, load_failed на ЛЮБОЙ ступени
(контейнеру нужен сам файл в маунт-каталоге). Решение: ХАРДЛИНКИ
(`ln -f` — тот же инод, 0 байт копий, контейнер видит регулярный файл);
SKIP download_file по хардлинкам тоже работает. Второй урок: `pkill -f
"<имя скрипта>"` из оркестраторской ssh-команды убивает и себя (паттерн
в собственной cmdline) — остановку фоновых EXP делать kill PID.

## F18 · 27b-multi (2×163840) живой на evo — IQ4_XS (мини-окно 2026-11-17)
`gfctl use 27b-multi`: гейт ≥56 OK, загрузка **15 с**, роут
`dflash2, sessions 2, ctx 163840`, SMOKE 3/3, повторный use идемпотентен
(recreate без утечек порта). Агрегат 2-пар (2×600 completion-ток,
merge/quick sort, greedy): **46.3 и 51.0 tok/s** — референс 29.5 снят на
Q4_K_XL (F7), на IQ4_XS существенно выше (квант легче; сценарий замера
отличается — 2 параллельных код-запроса по 600 ток). Числа — BENCH.md
llm-lab секция «EXP-004». probe-лестница (196608→…) — этап 2, в окне не
задействована (фиксированный канон 163840).

## F16 · Watchdog-паттерн (hfctl-опыт)
`restart: unless-stopped` не работает rootless после `podman run -d`
(kill-тест): контейнер остаётся Exited. Автоподнятие = systemd timer 1 мин →
`gfctl _watchdog` → up при отсутствии маркера `.gfctl-stopped`; явная
остановка только через `gfctl off`.
