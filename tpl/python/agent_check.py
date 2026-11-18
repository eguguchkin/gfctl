#!/usr/bin/env python3
# Назначение: HTTP/математика `gfctl agent-check` (SPEC §7) и контрольного
#   follow-up `gfctl cache --verify` — детерминированные POST
#   /v1/chat/completions с конвертом окон FX/CX (temperature 0 = greedy,
#   reasoning_effort "none", max_tokens по сценарию; НЕ /no_think и НЕ
#   chat_template_kwargs). Тайминги читаются ИЗ ТЕЛА ОТВЕТА
#   (timings.prompt_ms, component_cache.reuse = none|live|disk) — парсинг
#   логов для цифр не нужен; timings отсутствует → структурный FAIL (rc 1,
#   stderr-причина) — так деградирует смена ревизии gufo, не тихо.
#   Оркестрация/референсы/rc — bash (lib/agentcheck.sh, commands.sh);
#   здесь только транспорт, генерация промптов (литералы файла; F12:
#   bench-фикстура к agent-check отношения не имеет) и печать строк
#   `CHECK <имя> key=val…`, которые парсит bash.
#
# Режимы (argv[1]):
#   stage1       — agent-check до рестарта: сессия 15 ходов (doc ~6.6k из
#                  16 фактов ×11, история растёт) + follow-up-лестница
#                  5k/25k/100k (turn1+turn2 = 6 запросов) + [док 25k][q1→q2]
#                  + turn1 restore-разговора (состояние → $GFCTL_AGENT_STATE);
#                  24 запроса; печатает CHECK session/followup/docq.
#   stage2       — agent-check после рестарта: ход того же restore-разговора
#                  (первый запрос после recreate — ОДИН ретрай, F15);
#                  печатает CHECK restore turn2=… reuse=….
#   cacheverify1 — cache --verify до рестарта: doc 5k → q1 → follow-up
#                  (2 запроса), состояние → $GFCTL_AGENT_STATE;
#                  печатает CHECK cacheverify turn2=… reuse=….
#   cacheverify2 — cache --verify после рестарта: ход того же разговора
#                  (1 запрос, один ретрай); печатает CHECK restore ….
#
# Побочные эффекты: http-запросы (transport — curl из PATH, -m 1200 как в
#   окнах; faux-bin-шов батареи); запись $GFCTL_AGENT_STATE (JSON
#   messages+ответы) в stage1/cacheverify1 — путь даёт bash.
#
# Ограничения/допущения: stdlib only; порт — argv[2] (fallback env
#   GFCTL_AGENT_PORT), модель — argv[3] (ROUTE_MODEL с пробелами идёт как
#   одно значение argv, в JSON — json.dumps); ретрай РОВНО ОДИН и только
#   у первого запроса прогона (прогрев ядер, F15; пауза
#   GFCTL_SMOKE_RETRY_S, дефолт 15); промпты без IP/хостов.
#
# @param 1: stage1|stage2|cacheverify1|cacheverify2
# @param 2: /^[0-9]+$/     # порт сервера
# @param 3: string         # имя модели (ROUTE_MODEL)
# @stdout string           # прогресс-строки + CHECK-строки
# @returns integer         # 0 — все запросы отработали; 1 — структурный
#   провал (транспорт/JSON/timings/state), 2 — кривые аргументы
import json
import os
import subprocess
import sys
import time

TIMEOUT_S = 1200          # окна FX/CX: бюджет запроса с длинным префиллом
TAG = "gfctl-agentcheck"  # фиксированный маркер разговоров (детерминизм)
UNIT = ("Опиши подробно структуру связного списка, стека и очереди на Python, "
        "с примерами операций и оценкой сложности каждой операции. ")

# Рабочая записка сессии (протокол agent_bench окна HX-A: 16 фактов ×11 ≈
# 35k символов ≈ 6.6k ток) — факты о домене gufo/gfctl, без хостов/IP.
FACTS = [
    "gufo — движок вывода в образе gufo-runtime; сервер живёт в rootless podman с устройствами /dev/kfd и /dev/dri.",
    "драфт-спекуляция gufo: dflash2 для 27B и MTP для flash-next; draft_limit виден в load_completed.",
    "кэш gufo двухтирный: ram-cache с capacity_bytes и disk-тир с disk_capacity_bytes; ram_cache=on/off в строке configured.",
    "component-cache переживает рестарт сервера через disk-тир: следующий ход того же разговора восстанавливается за доли секунды.",
    "reuse в timings.component_cache принимает значения none, live и disk: none — префилл целиком, live — из RAM, disk — из disk-тира.",
    "контекст в мульти-профиле подбирается probe-лестницей по убыванию; первый загрузившийся ступень становится каноном пары.",
    "две сессии по 262144 на 27B движок отказывает в admission: «leave 0 MiB for the RAM cache above the host reserve».",
    "смена system-промпта ломает кэш: полный ре-префилл, cache_n обнуляется.",
    "gufo не имеет /health-эндпоинта: роут читается из лога load_completed — speculative, sessions, context_tokens, model.",
    "имена моделей gufo бывают с пробелами, например «Qwen3.8 Flash Next», — парсить подстроку до sessions=.",
    "метрика /metrics llamacpp:prompt_tokens_cached_total — счётчик переиспользованных prompt-токенов кэша.",
    "temperature 0 даёт greedy-декод, reasoning_effort none отключает рассуждения — конверт агентских запросов.",
    "фикстура bench merge_sort имеет md5 253c7ac5 — правка байтов теряет сравнимость прогонов.",
    "watchdog поднимает сервер раз в минуту при отсутствии маркера остановки; явная остановка только командой off.",
    "watch читает /metrics, /proc/meminfo и hwmon-температуры; логи движка — через podman logs -f.",
    "smoke после recreate делает один ретрай: первый запрос на прогреве ядер бывает пустым.",
]
QUESTIONS = [
    "Как устроен кэш gufo и из каких тиров он состоит?",
    "Что означает reuse в timings.component_cache и какие значения он принимает?",
    "Почему движок отказывает две сессии 262144 на 27B?",
    "Что происходит с кэшем при смене system-промпта?",
    "Где gufo публикует роут загрузки и какие поля там есть?",
    "Как парсить имя модели из load_completed?",
    "Какой счётчик /metrics показывает переиспользование кэша?",
    "Какой конверт запроса даёт greedy-декод без рассуждений?",
    "Зачем фиксировать md5 bench-фикстуры?",
    "Как watchdog решает, поднимать ли сервер?",
    "Какие источники данных у watch?",
    "Зачем smoke делает ретрай после recreate?",
    "Как подбирается контекст в мульти-профиле?",
    "Что даёт disk-тир для рестарт-restore?",
    "Какие устройства нужны rootless podman для ROCm?",
]
SYS_SHORT = "Ты — инженер-эксперт. Отвечай кратко."
RESTORE_Q1 = "Дай план из пяти пунктов."
RESTORE_Q2 = "Сократи план до одного пункта."
CV_Q1 = "Дай два пункта."
CV_Q2 = "Оставь один пункт."
CV_Q3 = "Назови сложность очереди."


class StructFail(Exception):
    """Структурный провал: транспорт/JSON/timings/state — rc 1 на вызывающем."""


def retry_pause():
    # @returns float  # пауза ретрая (env GFCTL_SMOKE_RETRY_S; дефолт 15, F15)
    try:
        return float(os.environ.get("GFCTL_SMOKE_RETRY_S") or 15)
    except ValueError:
        return 15.0


def post(url, model, messages, max_tokens, allow_retry):
    # @param 4: integer  # max_tokens сценария (сессия 128, follow-up/docq 64–96)
    # @param 5: bool     # True — у первого запроса прогона ОДИН ретрай (F15)
    # @returns (float, str, dict)  # (wall с, content, timings из тела)
    body = json.dumps({"model": model, "messages": messages,
                       "max_tokens": max_tokens, "temperature": 0,
                       "reasoning_effort": "none"}).encode()
    pause = retry_pause()
    for attempt in (1, 2):
        t0 = time.time()
        p = subprocess.run(
            ["curl", "-fsS", "-m", str(TIMEOUT_S),
             "-H", "Content-Type: application/json",
             "--data-binary", "@-", url],
            input=body, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        wall = time.time() - t0
        if p.returncode == 0 and p.stdout.strip():
            try:
                d = json.loads(p.stdout.decode("utf-8", "replace"))
            except ValueError:
                raise StructFail("ответ не JSON (битое тело) — смотри gfctl logs")
            t = d.get("timings")
            if not isinstance(t, dict):
                raise StructFail("timings отсутствует в ответе — проверь ревизию gufo "
                                 "(окна: timings в теле ответа)")
            try:
                ans = d["choices"][0]["message"]["content"]
            except (KeyError, IndexError, TypeError):
                raise StructFail("в ответе нет choices[0].message.content")
            if not (ans or "").strip():
                raise StructFail("пустой content в ответе (прогрев? ретрай не помог)")
            return wall, ans, t
        if attempt == 1 and allow_retry:
            print("первый запрос не ответил (curl rc=%s) — повторяю через %.0fs (F15)"
                  % (p.returncode, pause), flush=True)
            if pause > 0:
                time.sleep(pause)
            continue
        raise StructFail("запрос не ответил (curl rc=%s) — сервер жив? смотри gfctl logs"
                         % p.returncode)
    raise StructFail("unreachable")  # цикл всегда выходит через return/raise


def reuse_of(timings):
    # @returns string  # component_cache.reuse (none|live|disk); нет поля → none
    cc = timings.get("component_cache") or {}
    return cc.get("reuse") or "none"


def doc_k(approx_k):
    # @returns string  # детерминированный документ ~25 ток × 40k символов-повторов
    return UNIT * int(approx_k * 40)


def save_state(path, messages):
    # @raises StructFail  # отказ записи → структурный провал (вызывающий die)
    try:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"messages": messages}, fh, ensure_ascii=False)
    except OSError as e:
        raise StructFail("состояние не записано в %s: %s" % (path, e))


def load_state(path):
    # @returns list     # messages разговора из stage1/cacheverify1
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)["messages"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise StructFail("состояние не читается из %s: %s (первый чанк не запускался?)"
                         % (path, e))


def stage_session(url, model):
    # Сессия 15 ходов: doc ~6.6k + system + Q→A, история растёт (протокол
    # agent_bench); total wall = сумма стен ходов (референс 23.8 с @27b-single).
    doc = "\n".join("Факт %d: %s" % (i + 1, f) for i, f in enumerate(FACTS)) * 11
    msgs = [{"role": "system", "content":
             "Ты — инженер-эксперт по движкам вывода. Отвечай по записке, кратко, без рассуждений."},
            {"role": "user", "content":
             "Вот рабочая записка:\n%s\n\nОтвечай на вопросы только по ней." % doc}]
    total = 0.0
    for i, q in enumerate(QUESTIONS):
        full = msgs + [{"role": "user", "content": q}]
        w, ans, t = post(url, model, full, 128, allow_retry=(i == 0))
        total += w
        print("ход %d: wall=%.2fs prompt_ms=%s" % (i + 1, w, t.get("prompt_ms") or "?"), flush=True)
        msgs = full + [{"role": "assistant", "content": ans}]
    print("CHECK session total=%.2f" % total, flush=True)


def stage_ladder(url, model):
    # Follow-up-лестница 5k/25k/100k: turn1 (doc+вопрос) → turn2 (follow-up);
    # вердикт — только у 25k (bash), walls печатаются все.
    walls = {}
    for k in (5, 25, 100):
        base = [{"role": "system", "content": SYS_SHORT},
                {"role": "user", "content":
                 "%s\n[маркер %s-%dk]\nПеречисли ключевые структуры списком." % (doc_k(k), TAG, k)}]
        w1, ans, _ = post(url, model, base, 128, allow_retry=False)
        w2, _, t2 = post(url, model,
                         base + [{"role": "assistant", "content": ans},
                                 {"role": "user", "content":
                                  "Теперь главное ограничение одним предложением."}],
                         64, allow_retry=False)
        walls[k] = w2
        print("лестница %dk: turn1=%.2fs follow-up=%.2fs (reuse=%s)"
              % (k, w1, w2, reuse_of(t2)), flush=True)
    print("CHECK followup k5=%.2f k25=%.2f k100=%.2f"
          % (walls[5], walls[25], walls[100]), flush=True)


def stage_docq(url, model):
    # [док 25k][q1] → [док 25k][q2]: тот же документ в ДВУХ независимых
    # запросах — q2 быстрая на живом кэше (кэш-эффект).
    doc = doc_k(25)
    m1 = [{"role": "user", "content": "%s\n[маркер %s-docq]\nВопрос 1: назови три структуры." % (doc, TAG)}]
    w1, _, _ = post(url, model, m1, 96, allow_retry=False)
    m2 = [{"role": "user", "content": "%s\n[маркер %s-docq]\nВопрос 2: какая сложность у стека?" % (doc, TAG)}]
    w2, _, _ = post(url, model, m2, 64, allow_retry=False)
    print("docq: q1=%.2fs q2=%.2fs" % (w1, w2), flush=True)
    print("CHECK docq q2=%.2f" % w2, flush=True)


def stage1(url, model, state_path):
    if not state_path:
        raise StructFail("GFCTL_AGENT_STATE не задан — bash обязан дать путь state-файла")
    stage_session(url, model)
    stage_ladder(url, model)
    stage_docq(url, model)
    # (г)-turn1: разговор 25k для рестарт-restore; состояние → state-файл
    msgs = [{"role": "system", "content": SYS_SHORT},
            {"role": "user", "content": "%s\n[маркер %s-restore]\n%s" % (doc_k(25), TAG, RESTORE_Q1)}]
    w, ans, _ = post(url, model, msgs, 64, allow_retry=False)
    save_state(state_path, msgs + [{"role": "assistant", "content": ans}])
    print("restore: разговор 25k сохранён (turn1=%.2fs) → %s" % (w, state_path), flush=True)


def stage2(url, model, state_path):
    # После рестарта: ход того же разговора. reuse live|disk — disk-тир
    # работает; none — FAIL на вызывающем.
    full = load_state(state_path) + [{"role": "user", "content": RESTORE_Q2}]
    w, _, t = post(url, model, full, 64, allow_retry=True)  # первый после recreate
    print("CHECK restore turn2=%.2f reuse=%s" % (w, reuse_of(t)), flush=True)


def cacheverify1(url, model, state_path):
    if not state_path:
        raise StructFail("GFCTL_AGENT_STATE не задан — bash обязан дать путь state-файла")
    base = [{"role": "system", "content": SYS_SHORT},
            {"role": "user", "content": "%s\n[маркер %s-cv]\n%s" % (doc_k(5), TAG, CV_Q1)}]
    w1, ans, _ = post(url, model, base, 64, allow_retry=True)  # первый запрос прогона
    w2, ans2, t2 = post(url, model,
                        base + [{"role": "assistant", "content": ans},
                                {"role": "user", "content": CV_Q2}],
                        64, allow_retry=False)
    save_state(state_path, base + [{"role": "assistant", "content": ans},
                                   {"role": "user", "content": CV_Q2},
                                   {"role": "assistant", "content": ans2}])
    print("cacheverify: turn1=%.2fs follow-up=%.2fs (reuse=%s)"
          % (w1, w2, reuse_of(t2)), flush=True)
    print("CHECK cacheverify turn2=%.2f reuse=%s" % (w2, reuse_of(t2)), flush=True)


def cacheverify2(url, model, state_path):
    full = load_state(state_path) + [{"role": "user", "content": CV_Q3}]
    w, _, t = post(url, model, full, 64, allow_retry=True)  # первый после recreate
    print("CHECK restore turn2=%.2f reuse=%s" % (w, reuse_of(t)), flush=True)


def main(argv):
    mode = argv[0] if argv else ""
    if mode not in ("stage1", "stage2", "cacheverify1", "cacheverify2"):
        print("usage: agent_check.py <stage1|stage2|cacheverify1|cacheverify2> [port] [model]",
              file=sys.stderr)
        return 2
    port = argv[1] if len(argv) > 1 and argv[1] else os.environ.get("GFCTL_AGENT_PORT", "8080")
    model = argv[2] if len(argv) > 2 else ""
    state_path = os.environ.get("GFCTL_AGENT_STATE") or ""
    if not model:
        print("agent_check: модель не передана (argv[3]) — ROUTE_MODEL пуст?", file=sys.stderr)
        return 2
    url = "http://127.0.0.1:%s/v1/chat/completions" % port
    try:
        if mode == "stage1":
            stage1(url, model, state_path)
        elif mode == "stage2":
            stage2(url, model, state_path)
        elif mode == "cacheverify1":
            cacheverify1(url, model, state_path)
        else:
            cacheverify2(url, model, state_path)
    except StructFail as e:
        print("agent_check: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
