import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root

    pluginId: "npuAssistant"

    function tr(text) {
        return I18n.trFor("npuAssistant", text);
    }

    StringSetting {
        settingKey: "prefix"
        label: root.tr("Launcher prefix")
        description: root.tr("A launcher query starting with this is always sent to the assistant. The ? prefix is taken by the built-in settings search.")
        placeholder: "!"
        defaultValue: "!"
    }

    ToggleSetting {
        settingKey: "autoQuestions"
        label: root.tr("Answer obvious questions")
        description: root.tr("Also answer launcher queries that look like a question (ending with ? or starting with how, what, why…), not only ones with the prefix")
        defaultValue: true
    }

    SliderSetting {
        settingKey: "debounceMs"
        label: root.tr("Typing pause before asking")
        description: root.tr("How long the launcher waits after the last keystroke before sending the question to the NPU")
        defaultValue: 600
        minimum: 200
        maximum: 2000
        unit: "ms"
    }

    ToggleSetting {
        settingKey: "edgeTab"
        label: root.tr("Tab on the screen edge")
        description: root.tr("While the chat is hidden, a small tab on the right screen edge opens it with a click")
        defaultValue: true
    }

    SliderSetting {
        settingKey: "edgeTabPos"
        label: root.tr("Tab position")
        description: root.tr("Distance of the tab from the top of the screen")
        defaultValue: 40
        minimum: 5
        maximum: 90
        unit: "%"
    }

    StyledText {
        width: parent.width
        wrapMode: Text.Wrap
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        text: root.tr("Model, CPU boost cores, keep-warm time and memory/CPU thresholds are set in ~/.config/npu-assistant/config.json (see README). Open the chat with: dms ipc call npuAssistant toggle")
    }
}
