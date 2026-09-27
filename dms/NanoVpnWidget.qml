import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // 自动选择 = 订阅里的 urltest 组 tag
    readonly property string autoTag: "♻️ 自动选择"

    // 设置（pluginData 由 PluginComponent 从 settings.json 注入）
    property string nanoPath: pluginData.nanoPath || "nanovpn"
    property bool showNodeLabel: pluginData.showNodeLabel !== false

    function pollSeconds() {
        const v = parseInt(pluginData.pollInterval, 10);
        return isNaN(v) ? 3 : v;
    }

    property int pollIntervalSec: pollSeconds()

    // 运行状态（来自 nanovpn status --json）
    property string vpnState: "stopped" // connected | starting | stopped | error
    property string currentNode: ""
    property string currentMode: ""
    property bool tunEnabled: false
    property string exitIp: ""
    property string lastError: ""
    property bool cmdMissing: false

    // 弹层数据
    property var nodesList: []
    property var modesList: []
    property string selectedNode: ""
    property var panelInfo: ({})

    readonly property bool busy: vpnState === "starting"

    readonly property color statusColor: {
        switch (vpnState) {
        case "connected":
        case "starting":
            return Theme.primary;
        case "error":
            return Theme.error;
        default:
            return Theme.surfaceVariantText;
        }
    }

    // 节点列表：第一项固定为自动选择
    readonly property var nodeModel: {
        const auto = {
            "tag": autoTag,
            "type": "auto",
            "latency_ms": null,
            "isAuto": true
        };
        return [auto].concat(nodesList);
    }

    readonly property string statusLine: {
        if (cmdMissing)
            return I18n.trFor("nanoVpn", "nanovpn command not found");
        switch (vpnState) {
        case "connected":
            return exitIp ? I18n.trFor("nanoVpn", "Connected: %1 · Exit IP: %2").arg(shortLabel(currentNode)).arg(exitIp) : I18n.trFor("nanoVpn", "Connected: %1").arg(shortLabel(currentNode));
        case "starting":
            return I18n.trFor("nanoVpn", "Connecting: %1").arg(shortLabel(currentNode));
        case "error":
            return I18n.trFor("nanoVpn", "Error: %1").arg(lastError || I18n.trFor("nanoVpn", "unknown error"));
        default:
            return I18n.trFor("nanoVpn", "Not connected");
        }
    }

    readonly property string trafficLine: I18n.trFor("nanoVpn", "Traffic: %1 / %2").arg(formatBytes(panelInfo.used_bytes)).arg(formatBytes(panelInfo.total_bytes))
    readonly property string emailLine: panelInfo.email ? I18n.trFor("nanoVpn", "Account: %1").arg(panelInfo.email) : ""
    readonly property string expireLine: panelInfo.expire_at ? I18n.trFor("nanoVpn", "Expires: %1").arg(formatDate(panelInfo.expire_at)) : ""
    readonly property string checkinLine: I18n.trFor("nanoVpn", "Check-in days: %1").arg(panelInfo.checkin_days || 0)

    // 节点 tag 取简称：去掉 emoji，保留中英文与少量符号
    function shortLabel(tag) {
        if (!tag)
            return "";
        let out = "";
        for (const ch of tag) {
            const cp = ch.codePointAt(0);
            const keep = (cp >= 48 && cp <= 57) || (cp >= 65 && cp <= 90) || (cp >= 97 && cp <= 122) || (cp >= 0x4E00 && cp <= 0x9FFF) || cp === 45 || cp === 46 || cp === 40 || cp === 41;
            if (keep)
                out += ch;
        }
        return out.length > 8 ? out.slice(0, 8) : out;
    }

    function formatBytes(bytes) {
        const v = Number(bytes);
        if (!v || v <= 0)
            return "0 B";
        const units = ["B", "KB", "MB", "GB", "TB"];
        let i = 0;
        let n = v;
        while (n >= 1024 && i < units.length - 1) {
            n /= 1024;
            i++;
        }
        return (i === 0 ? n.toFixed(0) : n.toFixed(2)) + " " + units[i];
    }

    function formatDate(epochSec) {
        if (!epochSec)
            return "-";
        return Qt.formatDateTime(new Date(epochSec * 1000), "yyyy-MM-dd");
    }

    // 统一执行 nanovpn 子命令；包一层 sh 是因为 Quickshell 的 Process 在找不到
    // 可执行文件时不会触发 exited（回调永不返回），exec 失败会以 127 退出从而走错误分支
    function runCli(args, timeoutMs, onDone) {
        Proc.runCommand("nanoVpn." + args[0], ["sh", "-c", 'exec "$0" "$@"', nanoPath].concat(args), (out, code) => {
            if (onDone)
                onDone(out, code);
        }, 0, timeoutMs);
    }

    function notifyCmdMissing() {
        if (cmdMissing)
            return;
        cmdMissing = true;
        ToastService.showWarning(I18n.trFor("nanoVpn", "Nano VPN"), I18n.trFor("nanoVpn", "Cannot run %1, please run nanovpn install first").arg(nanoPath));
    }

    function notifyFailure(args) {
        ToastService.showError(I18n.trFor("nanoVpn", "Nano VPN"), I18n.trFor("nanoVpn", "Failed to run: %1").arg(args.join(" ")));
    }

    function fetchStatus() {
        runCli(["status", "--json"], 20000, (out, code) => {
            if (code !== 0) {
                notifyCmdMissing();
                return;
            }
            cmdMissing = false;
            let data = null;
            try {
                data = JSON.parse(out);
            } catch (e) {
                return;
            }
            if (!data)
                return;
            vpnState = data.state || "stopped";
            currentNode = data.node || "";
            currentMode = data.mode || "";
            tunEnabled = data.tun === true;
            exitIp = data.ip || "";
            lastError = data.error || "";
            if (currentNode)
                selectedNode = currentNode;
        });
    }

    function fetchPanel() {
        runCli(["panel", "--json"], 20000, (out, code) => {
            if (code !== 0) {
                notifyCmdMissing();
                return;
            }
            try {
                panelInfo = JSON.parse(out) || {};
            } catch (e) {
                panelInfo = {};
            }
        });
    }

    function fetchNodes() {
        runCli(["nodes", "--json"], 30000, (out, code) => {
            if (code !== 0) {
                notifyCmdMissing();
                return;
            }
            let data = null;
            try {
                data = JSON.parse(out);
            } catch (e) {
                return;
            }
            if (!data)
                return;
            nodesList = Array.isArray(data.nodes) ? data.nodes : [];
            modesList = (Array.isArray(data.modes) && data.modes.length > 0) ? data.modes : ["智能首选", "全球直连", "全局代理"];
            if (data.selected)
                selectedNode = data.selected;
            if (data.mode)
                currentMode = data.mode;
        });
    }

    function toggleConnection() {
        if (busy)
            return;
        if (vpnState === "connected") {
            runCli(["disconnect"], 30000, (out, code) => {
                if (code === 0)
                    ToastService.showInfo(I18n.trFor("nanoVpn", "Nano VPN"), I18n.trFor("nanoVpn", "Disconnected"));
                else
                    notifyFailure(["disconnect"]);
                fetchStatus();
            });
            return;
        }
        connectVpn(selectedNode);
    }

    function connectVpn(tag) {
        const args = ["connect"];
        if (tag)
            args.push(tag);
        if (tunEnabled)
            args.push("--tun");
        vpnState = "starting";
        runCli(args, 60000, (out, code) => {
            if (code === 0) {
                ToastService.showInfo(I18n.trFor("nanoVpn", "Nano VPN"), out.trim() || I18n.trFor("nanoVpn", "Connected"));
                fetchStatus();
                fetchNodes();
                return;
            }
            vpnState = "error";
            if (tunEnabled)
                ToastService.showError(I18n.trFor("nanoVpn", "Nano VPN"), I18n.trFor("nanoVpn", "Connect failed. TUN mode may need authorization: run nanovpn tun-setup"));
            else
                notifyFailure(args);
            fetchStatus();
        });
    }

    function setMode(mode) {
        if (!mode)
            return;
        currentMode = mode;
        runCli(["mode", mode], 20000, (out, code) => {
            if (code === 0)
                ToastService.showInfo(I18n.trFor("nanoVpn", "Nano VPN"), I18n.trFor("nanoVpn", "Mode switched to %1").arg(mode));
            else
                notifyFailure(["mode", mode]);
            fetchStatus();
        });
    }

    function setTun(on) {
        tunEnabled = on;
        if (vpnState === "stopped")
            return; // 未连接时先记住选择，下次连接带上 --tun
        const args = ["connect"];
        if (selectedNode)
            args.push(selectedNode);
        args.push(on ? "--tun" : "--no-tun");
        runCli(args, 60000, (out, code) => {
            if (code === 0) {
                ToastService.showInfo(I18n.trFor("nanoVpn", "Nano VPN"), on ? I18n.trFor("nanoVpn", "TUN mode enabled") : I18n.trFor("nanoVpn", "TUN mode disabled"));
                fetchStatus();
                return;
            }
            if (on)
                ToastService.showError(I18n.trFor("nanoVpn", "Nano VPN"), I18n.trFor("nanoVpn", "TUN mode needs authorization, please run nanovpn tun-setup"));
            else
                notifyFailure(args);
            fetchStatus();
        });
    }

    function doCheckin() {
        runCli(["checkin"], 30000, (out, code) => {
            const msg = out.trim();
            if (code === 0)
                ToastService.showInfo(I18n.trFor("nanoVpn", "Check-in"), msg || I18n.trFor("nanoVpn", "Checked in"));
            else
                ToastService.showWarning(I18n.trFor("nanoVpn", "Check-in"), msg || I18n.trFor("nanoVpn", "Check-in failed"));
            fetchPanel();
            fetchStatus();
        });
    }

    function testLatency() {
        ToastService.showInfo(I18n.trFor("nanoVpn", "Nano VPN"), I18n.trFor("nanoVpn", "Testing node latency..."));
        runCli(["nodes", "--test"], 60000, (out, code) => {
            if (code === 0)
                ToastService.showInfo(I18n.trFor("nanoVpn", "Nano VPN"), I18n.trFor("nanoVpn", "Latency test finished"));
            else
                notifyFailure(["nodes", "--test"]);
            fetchNodes();
        });
    }

    function promptLogin() {
        ToastService.showInfo(I18n.trFor("nanoVpn", "Nano VPN"), I18n.trFor("nanoVpn", "Please run nanovpn login in a terminal to sign in"));
    }

    Timer {
        interval: root.pollIntervalSec * 1000
        running: true
        repeat: true
        onTriggered: root.fetchStatus()
    }

    Component.onCompleted: root.fetchStatus()

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                id: pillIcon
                name: "vpn_lock"
                size: root.iconSize - 4
                color: root.statusColor
            }

            StyledText {
                visible: root.showNodeLabel && text.length > 0
                text: (root.vpnState === "connected" || root.vpnState === "starting") ? root.shortLabel(root.currentNode) : ""
                color: root.statusColor
                font.pixelSize: Theme.fontSizeSmall
            }

            // 连接中：图标呼吸动画
            OpacityAnimator {
                target: pillIcon
                from: 0.35
                to: 1
                duration: 800
                loops: Animation.Infinite
                running: root.vpnState === "starting"
                easing.type: Easing.InOutSine
                onRunningChanged: if (!running) pillIcon.opacity = 1
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                id: vPillIcon
                name: "vpn_lock"
                size: root.iconSize - 4
                color: root.statusColor
            }

            StyledText {
                visible: root.showNodeLabel && text.length > 0
                text: (root.vpnState === "connected" || root.vpnState === "starting") ? root.shortLabel(root.currentNode) : ""
                color: root.statusColor
                font.pixelSize: Theme.fontSizeSmall
                horizontalAlignment: Text.AlignHCenter
            }

            OpacityAnimator {
                target: vPillIcon
                from: 0.35
                to: 1
                duration: 800
                loops: Animation.Infinite
                running: root.vpnState === "starting"
                easing.type: Easing.InOutSine
                onRunningChanged: if (!running) vPillIcon.opacity = 1
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: I18n.trFor("nanoVpn", "Nano VPN")
            detailsText: root.statusLine
            showCloseButton: true

            Component.onCompleted: {
                root.fetchPanel();
                root.fetchNodes();
            }

            // 弹层每次打开时立即刷新，可见期间每 10s 再刷新
            Timer {
                interval: 10000
                repeat: true
                running: popout.parentPopout ? popout.parentPopout.shouldBeVisible : false
                onRunningChanged: if (running) {
                    root.fetchPanel();
                    root.fetchNodes();
                }
                onTriggered: {
                    root.fetchPanel();
                    root.fetchNodes();
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingM

                DankButton {
                    width: parent.width
                    text: root.busy ? I18n.trFor("nanoVpn", "Connecting...") : (root.vpnState === "connected" ? I18n.trFor("nanoVpn", "Disconnect") : I18n.trFor("nanoVpn", "Connect"))
                    iconName: root.vpnState === "connected" ? "link_off" : "power_settings_new"
                    buttonHeight: 44
                    enabled: !root.busy
                    backgroundColor: root.vpnState === "connected" ? Theme.surfaceContainerHigh : Theme.primary
                    textColor: root.vpnState === "connected" ? Theme.surfaceText : Theme.primaryText
                    onClicked: root.toggleConnection()
                }

                StyledText {
                    text: I18n.trFor("nanoVpn", "Mode")
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                }

                DankFilterChips {
                    id: modeChips
                    width: parent.width
                    model: root.modesList
                    onSelectionChanged: index => root.setMode(root.modesList[index])

                    Component.onCompleted: currentIndex = root.modesList.indexOf(root.currentMode)
                }

                Connections {
                    target: root
                    function onCurrentModeChanged() {
                        modeChips.currentIndex = root.modesList.indexOf(root.currentMode);
                    }
                    function onModesListChanged() {
                        modeChips.currentIndex = root.modesList.indexOf(root.currentMode);
                    }
                }

                DankToggle {
                    id: tunToggle
                    width: parent.width
                    text: I18n.trFor("nanoVpn", "TUN Mode")
                    checked: root.tunEnabled
                    onToggled: checked => root.setTun(checked)
                }

                StyledText {
                    text: I18n.trFor("nanoVpn", "Nodes")
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                }

                DankListView {
                    id: nodesView
                    width: parent.width
                    height: 190
                    clip: true
                    spacing: Theme.spacingXXS
                    model: root.nodeModel

                    delegate: StyledRect {
                        required property var modelData

                        width: nodesView.width
                        height: 40
                        radius: Theme.cornerRadius
                        color: nodeArea.containsMouse ? Theme.surfaceContainerHighest : (modelData.tag === root.selectedNode ? Theme.surfaceContainerHigh : "transparent")

                        Item {
                            anchors.fill: parent

                            DankIcon {
                                id: nodeIcon
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                name: modelData.isAuto ? "refresh" : (modelData.type === "tuic" ? "speed" : "public")
                                size: Theme.iconSizeSmall
                                color: modelData.tag === root.selectedNode ? Theme.primary : Theme.surfaceVariantText
                            }

                            StyledText {
                                anchors.left: nodeIcon.right
                                anchors.leftMargin: Theme.spacingS
                                anchors.right: nodeMeta.left
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.isAuto ? I18n.trFor("nanoVpn", "♻️ Auto Select") : (modelData.tag || "")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                            }

                            Row {
                                id: nodeMeta
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingS

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.isAuto ? "" : (modelData.type || "")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }

                                StyledText {
                                    width: 56
                                    horizontalAlignment: Text.AlignRight
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: (modelData.latency_ms === null || modelData.latency_ms === undefined) ? "—" : (modelData.latency_ms + " ms")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                            }
                        }

                        MouseArea {
                            id: nodeArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.connectVpn(modelData.tag)
                        }
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: root.panelInfo.logged_in !== undefined

                    StyledText {
                        width: parent.width
                        text: root.trafficLine
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                    }

                    StyledText {
                        width: parent.width
                        text: root.emailLine
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM

                        StyledText {
                            text: root.expireLine
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            text: root.checkinLine
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                Flow {
                    width: parent.width
                    spacing: Theme.spacingS

                    DankButton {
                        text: I18n.trFor("nanoVpn", "Refresh Nodes")
                        iconName: "refresh"
                        buttonHeight: 32
                        backgroundColor: Theme.surfaceContainerHigh
                        textColor: Theme.surfaceText
                        onClicked: {
                            root.fetchNodes();
                            ToastService.showInfo(I18n.trFor("nanoVpn", "Nano VPN"), I18n.trFor("nanoVpn", "Node list refreshed"));
                        }
                    }

                    DankButton {
                        text: I18n.trFor("nanoVpn", "Test Latency")
                        iconName: "network_check"
                        buttonHeight: 32
                        backgroundColor: Theme.surfaceContainerHigh
                        textColor: Theme.surfaceText
                        onClicked: root.testLatency()
                    }

                    DankButton {
                        text: I18n.trFor("nanoVpn", "Check In")
                        iconName: "check"
                        buttonHeight: 32
                        backgroundColor: Theme.surfaceContainerHigh
                        textColor: Theme.surfaceText
                        onClicked: root.doCheckin()
                    }

                    DankButton {
                        text: I18n.trFor("nanoVpn", "Login")
                        iconName: "login"
                        buttonHeight: 32
                        backgroundColor: Theme.surfaceContainerHigh
                        textColor: Theme.surfaceText
                        onClicked: root.promptLogin()
                    }
                }
            }
        }
    }

    popoutWidth: 420
    popoutHeight: 640
}
