import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.DCommon.Widgets
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
            let s = null;
            s = root.startStream({
                "message": q,
                "device": "npu",
                "save": false
            }, (name, d) => {
                // Taken over by the chat (Enter while the answer was still coming)
                if (root.adopted && root.adopted.stream === s) {
                    root.adoptedEvent(name, d);
                    return;
                }
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
            }, () => {
                if (root.adopted && root.adopted.stream === s)
                    root.adoptedEnded();
            });
            root.lstream = s;
        }
    }

    // A launcher answer still being generated, moved into the chat instead of being asked again
    property var adopted: null          // {stream, q, seq}

    function adoptedEvent(name, d) {
        const a = adopted;
        if (a.seq !== streamSeq)
            return;
        if (name === "token") {
            streamText += d.t;
            return;
        }
        if (name !== "done" && name !== "error")
            return;
        const m = messages.slice();
        m[m.length - 1] = Object.assign({}, m[m.length - 1], {
            "content": streamText,
            "pending": false,
            "stats": name === "done" ? d : null,
            "error": name === "error" ? errorText(d) : undefined
        });
        messages = m;
        if (name === "done" && streamText.trim() !== "")
            api("POST", "/history", {
                "messages": [
                    {
                        "role": "user",
                        "content": a.q,
                        "device": "npu"
                    },
                    {
                        "role": "assistant",
                        "content": streamText.trim(),
                        "device": "npu"
                    }
                ]
            }, data => {
                if (data && data.session && a.seq === streamSeq)
                    sessionId = data.session;
            });
    }

    function adoptedEnded() {
        const a = adopted;
        adopted = null;
        chatStream = null;
        if (a.seq === streamSeq && messages.length && messages[messages.length - 1].pending) {
            const m = messages.slice();
            m[m.length - 1] = Object.assign({}, m[m.length - 1], {
                "content": streamText,
                "pending": false
            });
            messages = m;
        }
        refreshStatus();
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

    // Enter on the launcher item: keep the finished answer as a chat, let the chat take over an answer
    // still being generated, or ask in the chat if the launcher had not asked yet.
    function continueInChat() {
        const q = lq, a = lanswer, done = ldone && !lerror && a.trim() !== "";
        launcherDebounce.stop();
        lq = "";
        if (lstream && !ldone && !generating) {
            const s = lstream;
            lstream = null;
            newChat();
            streamText = a;
            messages = [
                {
                    "role": "user",
                    "content": q
                },
                {
                    "role": "assistant",
                    "content": "",
                    "device": "npu",
                    "pending": true
                }
            ];
            adopted = {
                "stream": s,
                "q": q,
                "seq": streamSeq
            };
            chatStream = s;
            showPanel();
            return;
        }
        if (lstream)
            lstream.stop();
        lstream = null;
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
    // Exclusive keyboard only right after opening; released when the user turns to other windows
    property bool grabKeys: false

    Connections {
        target: NiriService
        function onLastFocusedWindowIdChanged() {
            root.grabKeys = false;
        }
    }

    function showPanel(screenName) {
        const focused = screenName || (CompositorService.getFocusedScreen()?.name ?? "");
        const target = slideouts.find(s => s?.modelData?.name === focused) ?? slideouts[0];
        grabKeys = true;
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

        delegate: DSlideout {
            id: chatSlideout
            title: root.tr("Assistant")
            slideoutWidth: 520
            expandable: true
            expandedWidthValue: 900
            // niri gives an on-demand layer the keyboard only after a click, so the chat grabs it when it
            // opens (type right away) and drops to on-demand once the user turns to other windows; a click
            // in the chat brings the keyboard back, and the chat stays open until Escape or ✕
            WlrLayershell.keyboardFocus: !isVisible ? WlrKeyboardFocus.None : root.grabKeys ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand
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

    // Tab on the right screen edge while the chat is hidden: the chat slides away to it and comes back
    // with a click, so it can be found without remembering the shortcut
    Variants {
        model: (pluginData.edgeTab ?? true) ? Quickshell.screens : []

        delegate: PanelWindow {
            id: edgeTab
            required property var modelData
            screen: modelData
            visible: !root.panelOpen
            color: "transparent"
            anchors.top: true
            anchors.right: true
            margins.top: Math.round((modelData?.height ?? 800) * (pluginData.edgeTabPos ?? 40) / 100)
            implicitWidth: 30
            implicitHeight: 56
            WlrLayershell.namespace: "dms:npu-assistant-tab"
            WlrLayershell.layer: WlrLayershell.Top
            WlrLayershell.exclusiveZone: -1
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            mask: Region {
                item: tabBody
            }

            StyledRect {
                id: tabBody
                anchors.right: parent.right
                width: tabMouse.containsMouse ? 30 : 20
                height: parent.height
                topLeftRadius: 16
                bottomLeftRadius: 16
                topRightRadius: 0
                bottomRightRadius: 0
                color: tabMouse.containsMouse ? Theme.surfaceContainerHigh : Theme.surfaceContainer
                opacity: tabMouse.containsMouse ? 1 : 0.8

                Behavior on width {
                    NumberAnimation {
                        duration: 120
                        easing.type: Easing.OutCubic
                    }
                }

                DIcon {
                    anchors.centerIn: parent
                    name: tabMouse.containsMouse ? "chevron_left" : "neurology"
                    size: 16
                    color: root.generating ? Theme.warning : Theme.primary
                }

                MouseArea {
                    id: tabMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.showPanel(edgeTab.modelData?.name ?? "")
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
