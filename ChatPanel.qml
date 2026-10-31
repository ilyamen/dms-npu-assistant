import QtQuick
import qs.Common
import qs.DCommon.Widgets
import qs.Services
import qs.Widgets

Item {
    id: root

    property var service: null
    property var slideout: null
    property bool showHistory: false

    // Index of the oldest message the model still saw when it gave the latest answer
    readonly property int firstRemembered: {
        const m = service.messages;
        for (let i = m.length - 1; i >= 0; i--)
            if (m[i].stats && m[i].stats.kept !== undefined)
                return Math.max(0, i - m[i].stats.kept);
        return 0;
    }


    function tr(text) {
        return I18n.trFor("npuAssistant", text);
    }

    function submit(device) {
        if (service.send(input.text, device)) {
            input.text = "";
            // Asked from elsewhere (pointer not on the chat): hand the keyboard back while the answer comes
            if (!hover.hovered)
                service.grabKeys = false;
        }
    }

    // Leaving the chat with nothing typed hands the keyboard back to the other windows
    HoverHandler {
        id: hover
        onHoveredChanged: if (!hovered && input.text.trim() === "")
            root.service.grabKeys = false
    }

    // The content is created after the slideout reveals itself, so focus the field once it is on screen
    Timer {
        id: focusTimer
        property int tries: 0
        interval: 100
        repeat: true
        onRunningChanged: if (running)
            tries = 0
        onTriggered: {
            input.forceActiveFocus();
            if (input.getActiveFocus() || ++tries > 20)
                stop();
        }
    }

    Component.onCompleted: focusTimer.start()

    Connections {
        target: root.slideout
        function onRevealed() {
            focusTimer.restart();
        }
    }

    // Toolbar: status, model, unload, history, new chat
    Row {
        id: toolbar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.spacingL
        anchors.rightMargin: Theme.spacingL
        spacing: Theme.spacingS

        DIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: "circle"
            size: 10
            filled: true
            color: {
                const st = root.service.modelState;
                return st === "down" || st === "error" ? Theme.error : st === "ready" ? Theme.primary : st === "off" ? Theme.surfaceVariantText : Theme.warning;
            }
        }

        StyledText {
            width: parent.width - 10 - 3 * 32 - modelPicker.width - 5 * Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            elide: Text.ElideRight
            text: {
                const s = root.service.status;
                if (!s)
                    return root.tr("The assistant service is not running");
                const st = root.service.modelState;
                let t = st === "down" ? root.tr("Strata is not running") : st === "ready" ? root.tr("ready") : st === "off" ? root.tr("asleep, loads with the first question") : st === "loading" ? root.tr("loading") : (s.npu.error || st);
                if (root.service.useStrata)
                    return t;
                if (s.cpu.state === "ready")
                    t += "  ·  ⚡ " + root.tr("warm") + (s.cpu.warm_left_s > 0 ? " " + Math.ceil(s.cpu.warm_left_s / 60) + " " + root.tr("min") : "");
                else if (s.cpu.state === "loading")
                    t += "  ·  ⚡ " + root.tr("loading");
                return t;
            }
        }

        DDropdown {
            id: modelPicker
            anchors.verticalCenter: parent.verticalCenter
            compactMode: true
            dropdownWidth: 170
            popupWidth: 260
            alignPopupRight: true
            options: root.service.modelChoices.map(c => c.label)
            currentValue: (root.service.modelChoices.find(c => c.id === root.service.selectedModel) ?? root.service.modelChoices[0]).label
            onValueChanged: value => {
                const c = root.service.modelChoices.find(c => c.label === value);
                if (c && c.id !== root.service.selectedModel)
                    root.service.setModel(c.id);
            }
        }

        DActionButton {
            readonly property bool can: root.service.modelState === "ready" && !root.service.generating
            iconName: "eject"
            opacity: can ? 1 : 0.4
            tooltipText: root.tr("Unload the model and free the memory")
            onClicked: if (can)
                root.service.unloadModel()
        }

        DActionButton {
            iconName: root.showHistory ? "chat" : "history"
            tooltipText: root.showHistory ? root.tr("Back to chat") : root.tr("History")
            onClicked: {
                root.showHistory = !root.showHistory;
                if (root.showHistory)
                    root.service.loadSessions();
            }
        }

        DActionButton {
            iconName: "add_comment"
            tooltipText: root.tr("New chat")
            onClicked: {
                root.service.newChat();
                root.showHistory = false;
                input.forceActiveFocus();
            }
        }
    }

    // History list
    DListView {
        id: historyList
        visible: root.showHistory
        anchors.top: toolbar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Theme.spacingL
        spacing: Theme.spacingXS
        clip: true
        model: root.service.sessions

        delegate: StyledRect {
            required property var modelData
            width: historyList.width
            height: 52
            radius: Theme.cornerRadius
            color: modelData.id === root.service.sessionId ? Theme.primaryContainer : (rowMouse.containsMouse ? Theme.surfaceContainerHigh : Theme.surfaceContainer)

            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    root.service.openSession(modelData.id);
                    root.showHistory = false;
                }
            }

            Column {
                anchors.left: parent.left
                anchors.right: delBtn.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                StyledText {
                    width: parent.width
                    text: modelData.title
                    elide: Text.ElideRight
                    color: Theme.surfaceText
                }
                StyledText {
                    text: new Date(modelData.updated * 1000).toLocaleString(Qt.locale(), "d MMM, HH:mm") + " · " + modelData.n
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }

            DActionButton {
                id: delBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: Theme.spacingS
                iconName: "delete"
                tooltipText: root.tr("Delete")
                onClicked: root.service.deleteSession(modelData.id)
            }
        }

        StyledText {
            anchors.centerIn: parent
            visible: historyList.count === 0
            text: root.tr("No chats yet")
            color: Theme.surfaceVariantText
        }
    }

    // Messages
    DListView {
        id: messageList
        visible: !root.showHistory
        anchors.top: toolbar.bottom
        anchors.bottom: inputBar.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Theme.spacingL
        spacing: Theme.spacingM
        clip: true
        model: root.service.messages

        // Follow the answer while it grows, unless the user scrolled up to read. Jumping straight to the
        // end (no positionViewAtEnd re-layout of the whole list) keeps the text from twitching.
        property bool stick: true
        property bool autoScrolling: false
        function toEnd() {
            if (!stick || contentHeight <= height)
                return;
            autoScrolling = true;
            contentY = originY + contentHeight - height;
            autoScrolling = false;
        }
        onContentYChanged: if (!autoScrolling)
            stick = contentY >= originY + contentHeight - height - 24
        onCountChanged: {
            stick = true;
            Qt.callLater(positionViewAtEnd);
        }
        onContentHeightChanged: toEnd()
        onHeightChanged: toEnd()

        delegate: Item {
            id: msg
            required property var modelData
            required property int index
            readonly property bool mine: modelData.role === "user"
            readonly property bool live: !!modelData.pending && index === messageList.count - 1
            readonly property bool forgotten: index < root.firstRemembered
            readonly property string content: live ? root.service.streamText : (modelData.content || "")
            width: messageList.width
            height: divider.height + bubble.height + (meta.visible ? meta.height + 2 : 0)
            opacity: forgotten ? 0.45 : 1

            StyledText {
                id: divider
                width: parent.width
                readonly property bool shown: msg.index === root.firstRemembered && msg.index > 0
                height: shown ? implicitHeight + Theme.spacingS : 0
                visible: shown
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                text: "↑ " + root.tr("the model no longer sees the messages above")
            }

            StyledRect {
                id: bubble
                anchors.top: divider.bottom
                anchors.right: mine ? parent.right : undefined
                // Assistant bubbles are full width, so a growing answer only grows down, never sideways
                width: mine ? Math.min(parent.width * 0.85, body.implicitWidth + 2 * Theme.spacingM) : parent.width
                height: body.height + 2 * Theme.spacingS
                radius: Theme.cornerRadius
                color: mine ? Theme.primaryContainer : Theme.surfaceContainer

                TextEdit {
                    id: body
                    x: Theme.spacingM
                    y: Theme.spacingS
                    width: mine ? Math.min(implicitWidth, messageList.width * 0.85 - 2 * Theme.spacingM) : bubble.width - 2 * Theme.spacingM
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    textFormat: mine ? TextEdit.PlainText : TextEdit.MarkdownText
                    color: modelData.error ? Theme.error : Theme.surfaceText
                    selectionColor: Theme.primary
                    font.pixelSize: Theme.fontSizeMedium
                    font.family: Theme.fontFamily ?? font.family
                    text: modelData.error ? (msg.content ? msg.content + "\n\n" : "") + modelData.error : (msg.content || (modelData.loading ? root.tr("Loading the model…") : "…"))
                }
            }

            StyledText {
                id: meta
                anchors.top: bubble.bottom
                anchors.topMargin: 2
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingS
                visible: !mine && !!modelData.device
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                text: (modelData.device === "cpu" ? "⚡ CPU" : modelData.device === "strata" ? "Strata" : "NPU") + (modelData.stats ? " · " + modelData.stats.tps + " tok/s · " + modelData.stats.tokens + " tok" + (modelData.stats.ctx ? " · " + root.tr("context") + " " + modelData.stats.ctx + "/" + modelData.stats.ctx_max : "") + (modelData.stats.trimmed ? " · " + root.tr("earlier answers shortened") : "") : "")
            }
        }

        StyledText {
            anchors.centerIn: parent
            width: parent.width * 0.8
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: messageList.count === 0
            text: root.tr("Ask anything. Answers run on the NPU; ⚡ sends the question to the CPU, which is faster while the computer is idle.")
            color: Theme.surfaceVariantText
        }
    }

    // Input
    Item {
        id: pasteWatcher
        Keys.onPressed: event => {
            if (event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier)) {
                Proc.runCommand("npuAssistant.types", ["wl-paste", "--list-types"], (out, code) => {
                    const types = out.split("\n");
                    const img = types.find(t => t.startsWith("image/"));
                    if (img && !types.some(t => t.startsWith("text/plain")))
                        root.service.sendImage(img);
                });
            } else if (event.key === Qt.Key_Escape) {
                root.slideout?.hide();
                event.accepted = true;
            } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
                root.submit(root.service.useStrata ? "npu" : "cpu");
                event.accepted = true;
            }
        }
    }

    Row {
        id: inputBar
        visible: !root.showHistory
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Theme.spacingL
        spacing: Theme.spacingS

        DTextField {
            id: input
            width: parent.width - (root.service.useStrata ? 1 : 2) * (40 + Theme.spacingS)
            placeholderText: root.service.useStrata ? root.tr("Message") : root.tr("Message (Ctrl+Enter — ⚡ CPU)")
            keyForwardTargets: [pasteWatcher]
            onAccepted: root.submit("npu")
            // Load the model once a question is really being typed, not just when the chat opens
            property bool typed: false
            onTextChanged: {
                const long = text.trim().length > 3;
                if (long && !typed)
                    root.service.warm();
                typed = long;
            }
        }

        DActionButton {
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.service.useStrata
            buttonSize: 40
            iconName: "bolt"
            iconColor: root.service.boostAvailable ? Theme.primary : Theme.surfaceVariantText
            opacity: root.service.boostAvailable && !root.service.generating ? 1 : 0.4
            tooltipText: root.service.boostAvailable ? root.tr("Ask on the CPU (EAGLE-3, faster when idle)") : root.service.boostReason
            onClicked: root.submit("cpu")
        }

        DActionButton {
            anchors.verticalCenter: parent.verticalCenter
            buttonSize: 40
            iconName: root.service.generating ? "stop" : "send"
            iconColor: Theme.primary
            tooltipText: root.service.generating ? root.tr("Stop") : root.tr("Send (NPU)")
            onClicked: root.service.generating ? root.service.stopGenerating() : root.submit("npu")
        }
    }
}
