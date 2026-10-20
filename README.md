# NPU Assistant for DankMaterialShell

A [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) plugin that puts a local AI assistant in the launcher and in a chat slideout. The model runs on the Intel NPU, so the assistant is always there and never takes the CPU or GPU from whatever you're doing. When the computer is idle, the ⚡ button sends a question to the CPU instead, which is about twice as fast.

Everything stays on the machine. The default model is Qwen3-4B-Instruct-2507 in our own INT4 build. On a Core Ultra 7 265K it answers at ~23 tok/s on the NPU and ~40–49 tok/s on the CPU boost. [docs/npu.md](docs/npu.md) explains how the NPU got there: a patch to Intel's NPU compiler and a Russian EAGLE-3 draft head.

## How it works

**Launcher.** Type a question into the launcher (Spotlight or the full launcher). A query starting with `!`, ending with `?`, or starting with a question word ("как", "что", "почему", "how", "what", "why"…) gets an answer item at the top. The answer streams in as the NPU generates it. The question is sent after a short pause in typing, and a changed query cancels the old answer. **Enter** opens the chat with the question and answer, so you can keep going. `?` itself is taken by the built-in settings search, so the explicit prefix is `!`. It can be changed in the settings.

**Chat.** A slideout with the conversation, a history of past chats (stored in SQLite), a stop button, and Markdown in answers. Text pastes as usual. A pasted image goes to an image hook, which says images aren't supported yet. Qwen3-4B has no vision, and the hook is where a VLM will go. Open the chat with:

```sh
dms ipc call npuAssistant toggle
```

or bind that to a key in niri. `dms ipc call npuAssistant ask "…"` and `… boost "…"` ask a question straight away.

**⚡ CPU boost.** The button (or Ctrl+Enter) sends the question to the CPU: the same model with our Russian EAGLE-3 head, speculative decoding with k=3. It runs in a separate process, niced and pinned to a configurable set of cores. The boost loads on first use in about 2 seconds and stays warm for 10 minutes. It unloads right away if free memory runs low. While other work keeps the CPU busy (by `/proc/pressure/cpu` or load average) or there isn't enough free memory to load it, the button is greyed out and its tooltip says why.

## Backend

The plugin talks to a small Python service, `npu-assistant`, running as a systemd user service on `127.0.0.1:8737`. It needs nothing beyond the standard library and OpenVINO GenAI.

- **NPU**: always loaded. The prompt is limited to 1024 tokens and the response gets at least 256. To fit, earlier answers are first cut to their beginning, then the oldest turns are dropped. Each answer in the chat shows how much of the context it used, and the chat marks the messages the model no longer sees. Every request is built from its own chat's history, so chats don't affect each other. There is no KV cache between turns: each question re-reads the history it keeps. Sampling: Qwen's non-thinking settings with `presence_penalty` 1.5. The service runs the patched NPU compiler through `LD_LIBRARY_PATH`, with its own compile cache.
- **CPU boost**: loaded on demand, greedy decoding (repetition penalties break EAGLE draft validation in GenAI).

| | |
|---|---|
| `GET /status` | devices, boost availability and the reason when it isn't available |
| `POST /chat` | `{message, session?, device: npu\|cpu, save?, image?}` → server-sent events `session`, `status`, `token`, `done`, `error` |
| `GET /history`, `GET/DELETE /history/<id>` | chats |
| `POST /history` | save a finished launcher answer as a chat |
| `POST /cpu/unload` | unload the boost now |

Settings live in `~/.config/npu-assistant/config.json`. Every key is optional; see [`config.py`](backend/npu_assistant/config.py) for the full list and defaults:

```json
{
    "cpu_cores": "0-7",
    "cpu_nice": 10,
    "cpu_keep_warm_min": 10,
    "cpu_busy_psi": 25,
    "cpu_busy_load": 0.6,
    "mem_load_min_gb": 6,
    "mem_unload_gb": 3
}
```

A command-line client comes with it:

```sh
npu-ask "Как посмотреть занятые порты?"      # NPU
npu-ask -c "Как посмотреть занятые порты?"   # CPU boost
npu-ask status
npu-ask history
journalctl --user -u npu-assistant -f
```

## Requirements

- DMS 1.6.3 or newer
- An Intel NPU (Meteor Lake / Arrow Lake / Lunar Lake) with the `intel_vpu` driver and the user-space NPU driver
- A Python environment with `openvino_genai` (tested with 2026.4.1) and an OpenVINO model directory
- `curl`, `wl-clipboard`

The paths in `config.py` point at this machine's model builds. Set `model`, `cpu_draft_model` and `npu_lib_dir` for yours, or set `npu_lib_dir` to `""` to use the system NPU compiler.

## Installation

```sh
git clone https://github.com/ilyamen/dms-npu-assistant ~/.config/DankMaterialShell/plugins/npuAssistant
PYTHON=/path/to/venv/bin/python ~/.config/DankMaterialShell/plugins/npuAssistant/backend/install.sh
```

The script writes `~/.config/systemd/user/npu-assistant.service`, starts it and links `npu-ask` into `~/.local/bin`. No root needed. Then enable the plugin in Settings → Plugins. It is also in the registry `https://github.com/ilyamen/dms-plugin-registry.git`.

## Removal

```sh
systemctl --user disable --now npu-assistant
rm ~/.config/systemd/user/npu-assistant.service ~/.local/bin/npu-ask
```

The chat history is in `~/.local/share/npu-assistant/history.db`.

## License

MIT
