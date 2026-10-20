import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// Owns everything stateful: backend status, the launcher answer, the chat and the chat slideout.
// The launcher surface reaches it through PluginService.pluginDaemonInstances.
PluginComponent {
    id: root

    property var popoutService: null

    readonly property string pid: "npuAssistant"
    readonly property string baseUrl: "http://127.0.0.1:" + (pluginData.port || 8737)
    readonly property int debounceMs: pluginData.debounceMs ?? 600

    function tr(text) {
        return I18n.trFor(pid, text);
    }

    // ---- backend status -------------------------------------------------------------
    property var status: null
    readonly property bool online: status !== null
    readonly property bool boostAvailable: online && status.cpu.available
    readonly property string boostReason: !online ? tr("The assistant service is not running") : (status.cpu.message || "")

    function refreshStatus() {
        Proc.runCommand(pid + ".status", ["curl", "-s", "--max-time", "2", baseUrl + "/status"], (out, code) => {
            try {
                status = code === 0 ? JSON.parse(out) : null;
            } catch (e) {
                status = null;
            }
        });
    }

    Timer {
        interval: 3000
        repeat: true
        triggeredOnStart: true
        running: root.panelOpen
        onTriggered: root.refreshStatus()
    }

    function api(method, path, body, cb) {
        const cmd = ["curl", "-s", "--max-time", "5", "-X", method, "-H", "Content-Type: application/json"];
        if (body !== undefined)
            cmd.push("--data-binary", JSON.stringify(body));
        cmd.push(baseUrl + path);
        Proc.runCommand(pid + "." + method + path, cmd, (out, code) => {
            let data = null;
            try {
                data = code === 0 ? JSON.parse(out) : null;
            } catch (e) {}
            if (cb)
                cb(data);
        });
    }

    function errorText(err) {
        if (!err)
            return "";
        if (err.code === "backend_down")
            return tr("The assistant service is not running") + " (systemctl --user start npu-assistant)";
        if (err.code === "image_unsupported")
            return tr("Images are not supported yet");
        return err.message || err.code;
    }

    // One streaming request: curl prints the SSE stream line by line. Stopping the process closes
    // the connection, and the backend cancels the generation.
    Component {
        id: streamComp
        Process {
            id: stream

            property string url: ""
            property var body: ({})
            property string _event: ""
            property bool _gotEvent: false

            signal sse(string name, var data)
            signal ended

            command: ["curl", "-sN", "--connect-timeout", "2", "-H", "Content-Type: application/json", "--data-binary", JSON.stringify(body), url + "/chat"]

            stdout: SplitParser {
                onRead: raw => {
                    // SSE events end with an empty line, which SplitParser glues to the next one
                    const line = raw.trim();
                    if (line.startsWith("event: ")) {
                        stream._event = line.slice(7);
                    } else if (line.startsWith("data: ")) {
                        let data = null;
                        try {
                            data = JSON.parse(line.slice(6));
                        } catch (e) {
                            return;
                        }
                        stream._gotEvent = true;
                        stream.sse(stream._event, data);
                    }
                }
            }

            onExited: (exitCode, exitStatus) => {
                if (!_gotEvent && exitCode !== 0 && exitStatus === Process.NormalExit)
                    sse("error", {
                        "code": "backend_down",
                        "message": "backend_down"
                    });
                ended();
            }

            function stop() {
                running = false;
            }
        }
    }

    function startStream(body, onEvent, onEnd) {
        const s = streamComp.createObject(root, {
            "url": baseUrl,
            "body": body
        });
        if (!s) {
            console.warn("[npuAssistant] stream:", streamComp.errorString());
            return null;
        }
        s.sse.connect(onEvent);
        s.ended.connect(() => {
            if (onEnd)
                onEnd();
            s.destroy();
        });
        s.running = true;
        return s;
    }

    // ---- launcher answer ------------------------------------------------------------
    property string lq: ""
    property string lanswer: ""
    property bool ldone: false
    property var lerror: null
    property var lstats: null
    property var lstream: null
    signal launcherChanged

    Timer {
        id: launcherDebounce
        interval: root.debounceMs
        onTriggered: {
            const q = root.lq;
            root.lstream = root.startStream({
                "message": q,
                "device": "npu",
                "save": false
            }, (name, d) => {
                if (q !== root.lq)
                    return;
                if (name === "token")
                    root.lanswer += d.t;
                else if (name === "done") {
                    root.ldone = true;
                    root.lstats = d;
                } else if (name === "error") {
                    root.ldone = true;
                    root.lerror = d;
                }
                root.launcherChanged();
            }, null);
        }
    }

    function launcherAsk(q) {
        if (q === lq)
            return;
        if (lstream)
            lstream.stop();
        lstream = null;
        lq = q;
        lanswer = "";
        ldone = false;
        lerror = null;
        lstats = null;
        launcherDebounce.restart();
    }

    // Enter on the launcher item: keep the finished answer as a chat, or ask again in the chat.
    function continueInChat() {
        const q = lq, a = lanswer, done = ldone && !lerror && a.trim() !== "";
        if (lstream)
            lstream.stop();
        launcherDebounce.stop();
        lq = "";
        if (done) {
            api("POST", "/history", {
                "messages": [
                    {
                        "role": "user",
                        "content": q,
                        "device": "npu"
                    },
                    {
                        "role": "assistant",
                        "content": a.trim(),
                        "device": "npu"
                    }
                ]
            }, data => {
                if (data && data.session)
                    openSession(data.session);
            });
            messages = [
                {
                    "role": "user",
                    "content": q
                },
                {
                    "role": "assistant",
                    "content": a.trim(),
                    "device": "npu",
                    "stats": lstats
                }
            ];
            showPanel();
        } else {
            newChat();
            showPanel();
            send(q, "npu");
        }
    }

    // ---- chat -----------------------------------------------------------------------
    property string sessionId: ""
    property var messages: []           // {role, content, device, stats, error}
    property var chatStream: null
    property int streamSeq: 0           // bumped when the chat changes, so a stopping stream can't touch the new one
    property string streamText: ""      // the answer being generated; kept apart so the list isn't rebuilt per token
    readonly property bool generating: chatStream !== null
    property var sessions: []

    function newChat() {
        stopGenerating();
        streamSeq++;
        sessionId = "";
        messages = [];
    }

    function openSession(sid) {
        stopGenerating();
        streamSeq++;
        sessionId = sid;
        api("GET", "/history/" + sid, undefined, data => {
            if (data && sid === sessionId)
                messages = data;
        });
    }

    function loadSessions() {
        api("GET", "/history", undefined, data => sessions = data || []);
    }

    function deleteSession(sid) {
        api("DELETE", "/history/" + sid, undefined, () => {
            if (sid === sessionId)
                newChat();
            loadSessions();
        });
    }

    function stopGenerating() {
        if (chatStream)
            chatStream.stop();
    }

    function send(text, device) {
        text = (text || "").trim();
        if (!text || generating)
            return false;
        if (device === "cpu" && !boostAvailable) {
            ToastService.showWarning(tr("Boost is unavailable"), boostReason);
            return false;
        }
        const msgs = messages.slice();
        msgs.push({
            "role": "user",
            "content": text
        });
        msgs.push({
            "role": "assistant",
            "content": "",
            "device": device,
            "pending": true
        });
        streamText = "";
        messages = msgs;
        const seq = ++streamSeq;
        const update = patch => {
            if (seq !== streamSeq)
                return;
            const m = messages.slice();
            m[m.length - 1] = Object.assign({}, m[m.length - 1], patch);
            messages = m;
        };
        chatStream = startStream({
            "message": text,
            "device": device,
            "session": sessionId || null
        }, (name, d) => {
            if (name === "session")
                sessionId = d.id;
            else if (name === "token") {
                if (seq === streamSeq)
                    streamText += d.t;
            }
            else if (name === "status")
                update({
                    "loading": d.state === "loading"
                });
            else if (name === "done")
                update({
                    "content": streamText,
                    "pending": false,
                    "loading": false,
                    "stats": d
                });
            else if (name === "error")
                update({
                    "content": streamText,
                    "pending": false,
                    "loading": false,
                    "error": errorText(d)
                });
        }, () => {
            chatStream = null;
            update({
                "content": streamText,
                "pending": false,
                "loading": false
            });
            refreshStatus();
        });
        return true;
    }

    // Image paste goes through the backend hook, which answers "not supported" until a VLM is plugged in.
    function sendImage(mime) {
        Proc.runCommand(pid + ".paste", ["sh", "-c", "wl-paste --type '" + mime + "' | base64 -w0"], (out, code) => {
            if (code !== 0)
                return;
            startStream({
                "message": "",
                "device": "npu",
                "save": false,
                "image": {
                    "data": out,
                    "mime": mime
                }
            }, (name, d) => {
                if (name === "error")
                    ToastService.showInfo(errorText(d));
            }, null);
        });
    }

    // ---- slideout -------------------------------------------------------------------
    property bool panelOpen: false
    property var slideouts: []

    function showPanel() {
        const focused = CompositorService.getFocusedScreen()?.name ?? "";
        const target = slideouts.find(s => s?.modelData?.name === focused) ?? slideouts[0];
        for (const s of slideouts)
            if (s && s !== target && s.isVisible)
                s.hide();
        if (target)
            target.show();
        refreshStatus();
    }

    function togglePanel() {
        const open = slideouts.find(s => s?.isVisible);
        if (open)
            open.hide();
        else
            showPanel();
    }

    Variants {
        model: Quickshell.screens

        delegate: DankSlideout {
            id: chatSlideout
            title: root.tr("Assistant")
            slideoutWidth: 520
            expandable: true
            expandedWidthValue: 900
            // niri gives an on-demand layer the keyboard only after a click and takes it back when the
            // layer drops to on-demand, so the chat holds the keyboard while open, like the launcher;
            // Escape or ✕ closes it
            WlrLayershell.keyboardFocus: isVisible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            onIsVisibleChanged: root.panelOpen = root.slideouts.some(s => s?.isVisible)
            Component.onCompleted: root.slideouts = root.slideouts.concat([chatSlideout])
            Component.onDestruction: root.slideouts = root.slideouts.filter(s => s !== chatSlideout)

            content: Component {
                ChatPanel {
                    service: root
                    slideout: chatSlideout
                }
            }
        }
    }

    IpcHandler {
        target: "npuAssistant"

        function toggle(): string {
            root.togglePanel();
            return "ok";
        }

        function ask(question: string): string {
            root.newChat();
            root.showPanel();
            root.send(question, "npu");
            return "ok";
        }

        function open(session: string): string {
            root.openSession(session);
            root.showPanel();
            return "ok";
        }

        function boost(question: string): string {
            root.newChat();
            root.showPanel();
            return root.send(question, "cpu") ? "ok" : root.boostReason;
        }
    }

    Component.onCompleted: {
        // Always-active launcher mode, so "?…" and plain questions reach getItems() without a trigger
        if (PluginService.loadPluginData(pid, "noTrigger", null) === null)
            PluginService.savePluginData(pid, "noTrigger", true);
        refreshStatus();
    }
}
