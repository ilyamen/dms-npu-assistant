"""Defaults, overridable from ~/.config/npu-assistant/config.json (flat keys, same names)."""
import json
import os

CONFIG_PATH = os.path.expanduser("~/.config/npu-assistant/config.json")
DATA_DIR = os.path.expanduser("~/.local/share/npu-assistant")

DEFAULTS = {
    "host": "127.0.0.1",
    "port": 8737,
    "model": "/var/lib/ollama-models/npu/build/qwen3-4b-2507-cw-awq-all",
    "system_prompt": "Ты полезный ассистент на компьютере пользователя. Отвечай по-русски, если не попросили иначе. "
                     "Пиши кратко и по делу, без лишних вступлений. Не повторяйся.",
    # NPU: patched npu_compiler (CMX fix, see docs/), no EAGLE head
    "npu_lib_dir": "/var/lib/ollama-models/npu-dev/cid-rel",
    "npu_cache_dir": "/var/lib/ollama-models/npu/.npucache-cidrel",
    # 4096 costs almost nothing on short chats (22.4 vs 23 tok/s); a full one decodes at ~15 tok/s
    "npu_max_prompt_len": 4096,
    "npu_min_response_len": 256,
    "npu_prefill_chunk": 256,
    "npu_prefix_caching": True,   # reuse the KV of the history between turns: 1800-token history 5.4 s -> 0.8 s
    # CPU boost: same model + Russian EAGLE-3 head
    "cpu_draft_model": "/var/lib/ollama-models/npu/build/eagle3-qwen3-4b-2507-ru",
    "cpu_assistant_tokens": 3,
    "cpu_cache_dir": "/var/lib/ollama-models/npu/.npucache",
    "cpu_cores": "",              # e.g. "0-7" = P-cores of the 265K; "" = all
    "cpu_nice": 10,
    "cpu_keep_warm_min": 10,
    "cpu_max_new_tokens": 1024,
    "cpu_busy_psi": 25.0,         # /proc/pressure/cpu some avg10, %
    "cpu_busy_load": 0.6,         # loadavg1 / ncpu
    "mem_load_min_gb": 6.0,       # MemAvailable needed to load the boost
    "mem_unload_gb": 3.0,         # unload the boost right away below this
    # Qwen3 non-thinking sampling (as in ~/ai/npu/tools)
    "temperature": 0.7,
    "top_p": 0.8,
    "top_k": 20,
    "presence_penalty": 1.5,
}


def load():
    cfg = dict(DEFAULTS)
    try:
        with open(CONFIG_PATH) as f:
            cfg.update({k: v for k, v in json.load(f).items() if k in DEFAULTS})
    except FileNotFoundError:
        pass
    return cfg


def parse_cores(spec):
    """'0-7,12' -> {0..7, 12}; '' -> all CPUs."""
    if not spec:
        return set(range(os.cpu_count() or 1))
    out = set()
    for part in str(spec).split(","):
        a, _, b = part.strip().partition("-")
        out.update(range(int(a), int(b or a) + 1))
    return out
