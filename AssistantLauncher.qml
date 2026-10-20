import QtQuick
import qs.Common
import qs.Services

// Launcher surface: "!question" (or an obvious question) shows the NPU answer as it streams.
QtObject {
    id: root

    property var pluginService: null
    property string pluginId: "npuAssistant"

    readonly property var service: PluginService.pluginDaemonInstances[pluginId] ?? null
    readonly property var questionWords: ["как", "что", "почему", "зачем", "сколько", "где", "когда", "кто", "какой", "какая", "какие", "какое", "чем", "можно ли", "объясни", "расскажи", "how", "what", "why", "when", "where", "who", "which", "explain"]

    signal itemsChanged

    property Connections serviceConn: Connections {
        target: root.service
        function onLauncherChanged() {
            if (root.pluginService && typeof root.pluginService.requestLauncherUpdate === "function")
                root.pluginService.requestLauncherUpdate(root.pluginId);
        }
    }

    function tr(text) {
        return I18n.trFor(pluginId, text);
    }

    function question(query) {
        const q = (query || "").trim();
        // "?" is taken by the built-in settings search, so the explicit prefix is "!" by default
        const prefix = pluginService?.loadPluginData(pluginId, "prefix", "!") || "!";
        if (q.startsWith(prefix))
            return q.slice(prefix.length).trim();
        if (!(pluginService?.loadPluginData(pluginId, "autoQuestions", true) ?? true))
            return "";
        const words = q.split(/\s+/);
        if (words.length < 3)
            return "";
        if (q.endsWith("?"))
            return q;
        const low = q.toLowerCase();
        return questionWords.some(w => low.startsWith(w + " ")) ? q : "";
    }

    function oneLine(text) {
        return text.replace(/\s+/g, " ").trim();
    }

    function getItems(query) {
        const q = question(query);
        if (!q || !service)
            return [];
        service.launcherAsk(q);
        let name, comment, icon = "material:neurology";
        if (service.lerror) {
            name = service.errorText(service.lerror);
            comment = q;
            icon = "material:error_outline";
        } else if (!service.lanswer) {
            name = tr("Thinking…");
            comment = q;
        } else {
            const a = oneLine(service.lanswer);
            // Two lines at most: while streaming the newest text, when done the beginning
            name = a.length <= 100 ? a : service.ldone ? a.slice(0, 100) + "…" : "…" + a.slice(-100);
            const st = service.lstats;
            comment = (st ? "NPU · " + st.tps + " tok/s · " : "NPU · ") + tr("Enter — continue in chat");
        }
        return [
            {
                "name": name,
                "icon": icon,
                "comment": comment,
                "action": "chat",
                "categories": [tr("Assistant")],
                "_preScored": 950
            }
        ];
    }

    function executeItem(item) {
        if (service)
            service.continueInChat();
    }
}
