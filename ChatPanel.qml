import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: root

    property var service: null
    property var slideout: null
    property bool showHistory: false


    function tr(text) {
        return I18n.trFor("npuAssistant", text);
    }

    function submit(device) {
        if (service.send(input.text, device))
            input.text = "";
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

    // Toolbar: status, history, new chat
    Row {
        id: toolbar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.spacingL
        anchors.rightMargin: Theme.spacingL
        spacing: Theme.spacingS

        DankIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: "circle"
            size: 10
            filled: true
            color: !root.service.online ? Theme.error : root.service.status.npu.state === "ready" ? Theme.primary : Theme.warning
        }

        StyledText {
            width: parent.width - 10 - 2 * 32 - 3 * Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            elide: Text.ElideRight
            text: {
                const s = root.service.status;
                if (!s)
                    return root.tr("The assistant service is not running");
                let t = "NPU · " + (s.npu.state === "ready" ? root.tr("ready") : s.npu.state);
                if (s.cpu.state === "ready")
                    t += "  ·  ⚡ " + root.tr("warm") + (s.cpu.warm_left_s > 0 ? " " + Math.ceil(s.cpu.warm_left_s / 60) + " " + root.tr("min") : "");
                else if (s.cpu.state === "loading")
                    t += "  ·  ⚡ " + root.tr("loading");
                return t;
            }
        }

        DankActionButton {
            iconName: root.showHistory ? "chat" : "history"
            tooltipText: root.showHistory ? root.tr("Back to chat") : root.tr("History")
            onClicked: {
                root.showHistory = !root.showHistory;
                if (root.showHistory)
                    root.service.loadSessions();
            }
        }

        DankActionButton {
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
    DankListView {
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

            DankActionButton {
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
    DankListView {
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
        onCountChanged: Qt.callLater(positionViewAtEnd)
        onContentHeightChanged: if (root.service.generating)
            Qt.callLater(positionViewAtEnd)

        delegate: Item {
            required property var modelData
            readonly property bool mine: modelData.role === "user"
            width: messageList.width
            height: bubble.height + (meta.visible ? meta.height + 2 : 0)

            StyledRect {
                id: bubble
                anchors.right: mine ? parent.right : undefined
                width: Math.min(parent.width * (mine ? 0.85 : 1), body.implicitWidth + 2 * Theme.spacingM)
                height: body.height + 2 * Theme.spacingS
                radius: Theme.cornerRadius
                color: mine ? Theme.primaryContainer : Theme.surfaceContainer

                TextEdit {
                    id: body
                    x: Theme.spacingM
                    y: Theme.spacingS
                    width: Math.min(implicitWidth, messageList.width * (mine ? 0.85 : 1) - 2 * Theme.spacingM)
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    textFormat: mine ? TextEdit.PlainText : TextEdit.MarkdownText
                    color: modelData.error ? Theme.error : Theme.surfaceText
                    selectionColor: Theme.primary
                    font.pixelSize: Theme.fontSizeMedium
                    font.family: Theme.fontFamily ?? font.family
                    text: modelData.error ? (modelData.content ? modelData.content + "\n\n" : "") + modelData.error : (modelData.content || (modelData.loading ? root.tr("Loading the model…") : "…"))
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
                text: (modelData.device === "cpu" ? "⚡ CPU" : "NPU") + (modelData.stats ? " · " + modelData.stats.tps + " tok/s · " + modelData.stats.tokens + " tok" : "")
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
                root.submit("cpu");
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

        DankTextField {
            id: input
            width: parent.width - 2 * (40 + Theme.spacingS)
            placeholderText: root.tr("Message (Ctrl+Enter — ⚡ CPU)")
            keyForwardTargets: [pasteWatcher]
            onAccepted: root.submit("npu")
        }

        DankActionButton {
            anchors.verticalCenter: parent.verticalCenter
            buttonSize: 40
            iconName: "bolt"
            iconColor: root.service.boostAvailable ? Theme.primary : Theme.surfaceVariantText
            opacity: root.service.boostAvailable && !root.service.generating ? 1 : 0.4
            tooltipText: root.service.boostAvailable ? root.tr("Ask on the CPU (EAGLE-3, faster when idle)") : root.service.boostReason
            onClicked: root.submit("cpu")
        }

        DankActionButton {
            anchors.verticalCenter: parent.verticalCenter
            buttonSize: 40
            iconName: root.service.generating ? "stop" : "send"
            iconColor: Theme.primary
            tooltipText: root.service.generating ? root.tr("Stop") : root.tr("Send (NPU)")
            onClicked: root.service.generating ? root.service.stopGenerating() : root.submit("npu")
        }
    }
}
