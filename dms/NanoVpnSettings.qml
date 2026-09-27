import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "nanoVpn"

    StyledText {
        width: parent.width
        text: I18n.trFor("nanoVpn", "Nano VPN Settings")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: I18n.trFor("nanoVpn", "Configure how the Nano VPN bar widget behaves.")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    ToggleSetting {
        settingKey: "showNodeLabel"
        label: I18n.trFor("nanoVpn", "Show Node Label")
        description: I18n.trFor("nanoVpn", "Show the connected node name next to the icon in the bar")
        defaultValue: true
    }

    SelectionSetting {
        settingKey: "pollInterval"
        label: I18n.trFor("nanoVpn", "Status Poll Interval")
        description: I18n.trFor("nanoVpn", "How often the widget refreshes the VPN status")
        options: [
            {
                label: I18n.trFor("nanoVpn", "3 seconds"),
                value: "3"
            },
            {
                label: I18n.trFor("nanoVpn", "5 seconds"),
                value: "5"
            },
            {
                label: I18n.trFor("nanoVpn", "10 seconds"),
                value: "10"
            }
        ]
        defaultValue: "3"
    }

    StringSetting {
        settingKey: "nanoPath"
        label: I18n.trFor("nanoVpn", "nanovpn Command")
        description: I18n.trFor("nanoVpn", "Path or name of the nanovpn CLI used by the widget")
        placeholder: "nanovpn"
        defaultValue: "nanovpn"
    }
}
