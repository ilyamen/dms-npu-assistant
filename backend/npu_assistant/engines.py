"""NPU (always loaded, in-process) and CPU boost (on demand, separate niced process) engines."""
import multiprocessing as mp
import os
import threading
import time

from . import sysmon
from .config import parse_cores


class Unavailable(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


TRIM_CHARS = 500


def build_prompt(tok, system, history, budget):
    """Chat-template the history to fit `budget` tokens. First shorten earlier answers to their beginning
    (the model keeps the thread of the talk), then drop the oldest turns, then cut the last message.
    Returns (prompt, prompt tokens, how many of the last history messages made it in, whether answers were cut)."""
    msgs = [dict(m) for m in history]
    trimmed = False
    while True:
        p = tok.apply_chat_template([{"role": "system", "content": system}] + msgs, add_generation_prompt=True,
                                    extra_context={"enable_thinking": False})
        n = tok.encode(p).input_ids.shape[1]
        if n <= budget:
            return p, n, len(msgs), trimmed
        long = [m for m in msgs[:-1] if m["role"] == "assistant" and len(m["content"]) > TRIM_CHARS]
        if long:
            for m in long:
                m["content"] = m["content"][:TRIM_CHARS] + " …"
            trimmed = True
        elif len(msgs) > 1:
            msgs = msgs[2:] if len(msgs) > 2 else msgs[1:]
        else:
            c = msgs[0]["content"]
            msgs[0]["content"] = c[:max(1, int(len(c) * budget / n) - 16)]


def gen_config(pipe, cfg, max_new, greedy=False):
    gc = pipe.get_generation_config()
    gc.apply_chat_template = False
    gc.max_new_tokens = max_new
    if greedy:  # CPU + EAGLE: penalties break draft validation in GenAI ("input_ids token out of bounds")
        gc.do_sample = False
    else:
        gc.presence_penalty = cfg["presence_penalty"]
        gc.do_sample = True
        gc.temperature, gc.top_p, gc.top_k = cfg["temperature"], cfg["top_p"], cfg["top_k"]
    return gc


def run(ov_genai, pipe, prompt, gc, on_text, cancelled):
    def streamer(s):
        if s:
            on_text(s)
        return ov_genai.StreamingStatus.CANCEL if cancelled() else ov_genai.StreamingStatus.RUNNING

    t = time.perf_counter()
    r = pipe.generate([prompt], gc, streamer)
    dt = time.perf_counter() - t
    pm = r.perf_metrics
    n = pm.get_num_generated_tokens()
    ttft = pm.get_ttft().mean / 1000
    res = {"tokens": n, "ttft": round(ttft, 3), "tps": round(n / max(dt - ttft, 1e-3), 1), "text": r.texts[0]}
    em = getattr(r, "extended_perf_metrics", None)
    try:
        drafted = em.draft_model_metrics.get_num_generated_tokens()
        res["accepted"] = round(em.get_num_accepted_tokens() / max(drafted, 1), 2)
    except Exception:
        pass
    return res


class NpuEngine:
    def __init__(self, cfg):
        self.cfg = cfg
        self.state, self.error = "loading", None
        self.ready = threading.Event()
        self.lock = threading.Lock()
        self.busy = False
        threading.Thread(target=self._load, daemon=True).start()

    def _load(self):
        try:
            import openvino_genai as ov_genai
            c = self.cfg
            os.makedirs(c["npu_cache_dir"], exist_ok=True)
            t = time.time()
            self.ov = ov_genai
            self.pipe = ov_genai.LLMPipeline(c["model"], "NPU", MAX_PROMPT_LEN=c["npu_max_prompt_len"],
                                             MIN_RESPONSE_LEN=c["npu_min_response_len"],
                                             NPUW_LLM_PREFILL_CHUNK_SIZE=c["npu_prefill_chunk"],
                                             GENERATE_HINT="BEST_PERF", CACHE_DIR=c["npu_cache_dir"])
            self.tok = self.pipe.get_tokenizer()
            self.state = "ready"
            print(f"npu: loaded in {time.time() - t:.1f}s", flush=True)
        except Exception as e:
            self.state, self.error = "error", str(e)
            print(f"npu: load failed: {e}", flush=True)
        self.ready.set()

    def generate(self, history, on_text, cancelled, on_wait=None):
        if not self.ready.is_set() and on_wait:
            on_wait("loading")
        self.ready.wait()
        if self.state != "ready":
            raise Unavailable("npu_error", self.error)
        with self.lock:
            self.busy = True
            try:
                c = self.cfg
                prompt, n, kept, trimmed = build_prompt(self.tok, c["system_prompt"], history, c["npu_max_prompt_len"])
                total = c["npu_max_prompt_len"] + c["npu_min_response_len"]
                gc = gen_config(self.pipe, c, max(c["npu_min_response_len"], total - n))
                res = run(self.ov, self.pipe, prompt, gc, on_text, cancelled)
                res.update(ctx=n, ctx_max=c["npu_max_prompt_len"], kept=kept, trimmed=trimmed)
                return res
            finally:
                self.busy = False


CPU_PROMPT_BUDGET = 4096


def _cpu_worker(conn, cfg):
    """Child process: niced, pinned to cfg['cpu_cores'] before OpenVINO starts its threads."""
    os.nice(int(cfg["cpu_nice"]))
    os.sched_setaffinity(0, parse_cores(cfg["cpu_cores"]))
    import openvino_genai as ov_genai
    props = {"CACHE_DIR": cfg["cpu_cache_dir"]}
    try:
        pipe = ov_genai.LLMPipeline(cfg["model"], "CPU",
                                    draft_model=ov_genai.draft_model(cfg["cpu_draft_model"], "CPU", **props), **props)
    except Exception as e:
        conn.send(("error", str(e)))
        return
    tok = pipe.get_tokenizer()
    conn.send(("ready", None))
    while True:
        msg = conn.recv()
        if msg[0] == "quit":
            return
        if msg[0] != "gen":
            continue
        _, system, history = msg
        prompt, n, kept, trimmed = build_prompt(tok, system, history, CPU_PROMPT_BUDGET)
        gc = gen_config(pipe, cfg, int(cfg["cpu_max_new_tokens"]), greedy=True)
        gc.num_assistant_tokens = int(cfg["cpu_assistant_tokens"])
        stop = []

        def cancelled():
            while conn.poll():
                if conn.recv()[0] == "cancel":
                    stop.append(1)
            return bool(stop)
        try:
            res = run(ov_genai, pipe, prompt, gc, lambda s: conn.send(("tok", s)), cancelled)
            res.pop("text")
            res.update(ctx=n, ctx_max=CPU_PROMPT_BUDGET, kept=kept, trimmed=trimmed)
            conn.send(("done", res))
        except Exception as e:
            conn.send(("error", str(e)))


class CpuEngine:
    GRACE = 20  # s after our own generation during which CPU pressure is ours, not someone else's

    def __init__(self, cfg):
        self.cfg = cfg
        self.proc = self.conn = None
        self.state = "off"   # off | loading | ready
        self.busy = False
        self.lock = threading.Lock()      # one generation at a time
        self.plock = threading.RLock()    # process start/stop
        self.last_used = 0.0
        self.last_unload = None

    def availability(self):
        c = self.cfg
        mem = sysmon.mem_available_gb()
        if self.state == "off" and mem < c["mem_load_min_gb"]:
            return False, "low_memory", f"мало свободной памяти: {mem:.1f} ГБ < {c['mem_load_min_gb']} ГБ"
        if self.busy or self.state == "loading" or time.time() - self.last_used < self.GRACE:
            return True, "ok", ""
        psi, load = sysmon.cpu_psi_avg10(), sysmon.load_ratio()
        if psi > c["cpu_busy_psi"] or load > c["cpu_busy_load"]:
            return False, "cpu_busy", f"процессор занят: PSI {psi:.0f}%, load {load:.2f}/ядро"
        return True, "ok", ""

    def _start(self):
        ctx = mp.get_context("spawn")
        self.conn, child = ctx.Pipe()
        self.state = "loading"
        self.proc = ctx.Process(target=_cpu_worker, args=(child, self.cfg), daemon=True, name="npu-assistant-cpu")
        t = time.time()
        self.proc.start()
        kind, payload = self.conn.recv()
        if kind != "ready":
            self.unload("load_error")
            raise Unavailable("cpu_error", payload)
        self.state = "ready"
        print(f"cpu: boost loaded in {time.time() - t:.1f}s (pid {self.proc.pid})", flush=True)

    def unload(self, reason):
        with self.plock:
            if self.proc is None:
                return
            self.last_unload = reason
            try:
                self.conn.send(("quit",))
                self.proc.join(3)
            except Exception:
                pass
            if self.proc.is_alive():
                self.proc.kill()
                self.proc.join()
            self.proc = self.conn = None
            self.state = "off"
            print(f"cpu: boost unloaded ({reason})", flush=True)

    def tick(self):
        """Called every few seconds: free the boost on low memory or after the keep-warm time."""
        if self.proc is None:
            return
        if sysmon.mem_available_gb() < self.cfg["mem_unload_gb"]:
            self.unload("low_memory")
        elif not self.busy and self.state == "ready" and \
                time.time() - self.last_used > self.cfg["cpu_keep_warm_min"] * 60:
            with self.plock:
                if not self.busy:
                    self.unload("idle")

    def generate(self, history, on_text, cancelled, on_wait=None):
        ok, code, why = self.availability()
        if not ok:
            raise Unavailable(code, why)
        with self.lock:
            self.busy = True
            try:
                with self.plock:
                    if self.proc is None:
                        if on_wait:
                            on_wait("loading")
                        self._start()
                    conn = self.conn
                conn.send(("gen", self.cfg["system_prompt"], history))
                sent_cancel = False
                while True:
                    if not conn.poll(0.2):
                        if cancelled() and not sent_cancel:
                            conn.send(("cancel",))
                            sent_cancel = True
                        continue
                    kind, payload = conn.recv()
                    if kind == "tok":
                        on_text(payload)
                    elif kind == "done":
                        return payload
                    else:
                        raise Unavailable("cpu_error", payload)
            except (EOFError, OSError, BrokenPipeError):
                raise Unavailable("cpu_unloaded", f"буст выгружен: {self.last_unload or 'процесс завершился'}")
            finally:
                self.busy = False
                self.last_used = time.time()
