#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Install custom Gentoo SDDM theme (inline QML, no external deps)
set -eo pipefail

echo "============================="
echo " Gentoo SDDM Theme Install"
echo "============================="
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo "Run it with: sudo $0"
    exit 1
fi

THEME_DIR="/usr/share/sddm/themes/gentoo"
mkdir -p "$THEME_DIR" /etc/sddm.conf.d

# Qt6 SDDM builds rename the greeter binary but theme validation still checks
# the old name — create a compat symlink if needed
if [[ ! -e /usr/bin/sddm-greeter && -e /usr/bin/sddm-greeter-qt6 ]]; then
    ln -sf /usr/bin/sddm-greeter-qt6 /usr/bin/sddm-greeter
    echo "Created sddm-greeter compat symlink -> sddm-greeter-qt6"
fi

# The symlink defaults to bin_t after relabel; it needs xdm_exec_t so SELinux
# performs the correct domain transition when SDDM execs the greeter
if command -v semanage >/dev/null 2>&1 && [[ -L /usr/bin/sddm-greeter ]]; then
    semanage fcontext -a -t xdm_exec_t /usr/bin/sddm-greeter 2>/dev/null || \
    semanage fcontext -m -t xdm_exec_t /usr/bin/sddm-greeter 2>/dev/null || true
    restorecon /usr/bin/sddm-greeter
    echo "Set xdm_exec_t context on sddm-greeter symlink"
fi

# =============================================================================
# Gentoo logo — copy from GRUB theme (installed by default on Gentoo)
# =============================================================================

LOGO_CANDIDATES=(
    "/usr/share/grub/themes/gentoo_minimalist/gentoo_logo.png"
    "/usr/share/grub/themes/gentoo_frosted/logo_frosted.png"
    "/usr/share/grub/themes/gentoo_glass/logo_glass.png"
)
LOGO_COPIED=0
for _src in "${LOGO_CANDIDATES[@]}"; do
    if [[ -f "$_src" ]]; then
        cp "$_src" "${THEME_DIR}/logo.png"
        echo "Copied logo from ${_src}"
        LOGO_COPIED=1
        break
    fi
done
if (( LOGO_COPIED == 0 )); then
    echo "WARNING: No Gentoo logo found — theme will show a blank image in place of the logo."
    echo "         Install sys-boot/grub with Gentoo themes to provide the logo."
fi

# =============================================================================
# metadata.desktop
# =============================================================================

cat > "${THEME_DIR}/metadata.desktop" << 'EOF'
[SddmGreeterTheme]
Name=Gentoo
Description=Gentoo Linux login theme — dark with Gentoo purple
Author=Imperial-Corsair
License=GPL-3.0+
Type=sddm-theme
Version=1.0
MainScript=Main.qml
EOF

# =============================================================================
# Main.qml — full login screen
# =============================================================================

cat > "${THEME_DIR}/Main.qml" << 'EOF'
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15

Item {
    id: root
    width: Screen.width
    height: Screen.height

    // ── SDDM event handling ───────────────────────────────────────────────────
    Connections {
        target: sddm
        function onLoginFailed() {
            loginMessage.text = "Login failed — check your credentials."
            password.text = ""
            password.forceActiveFocus()
        }
    }

    // ── Background ────────────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: "#1a1a2e" }
            GradientStop { position: 1.0; color: "#0f0f1e" }
        }
    }

    // ── Login card ────────────────────────────────────────────────────────────
    Rectangle {
        id: card
        anchors.centerIn: parent
        width: 380
        height: cardLayout.implicitHeight + 72
        radius: 12
        color: "#252535"

        ColumnLayout {
            id: cardLayout
            anchors {
                top: parent.top
                left: parent.left
                right: parent.right
                topMargin: 36
                leftMargin: 36
                rightMargin: 36
            }
            spacing: 14

            // Gentoo logo
            Image {
                source: "logo.png"
                width: 80; height: 80
                fillMode: Image.PreserveAspectFit
                Layout.alignment: Qt.AlignHCenter
            }

            Text {
                text: "Gentoo Linux"
                color: "#cdd6f4"
                font.pixelSize: 20
                font.weight: Font.Medium
                Layout.alignment: Qt.AlignHCenter
            }

            // Error message (hidden when empty)
            Text {
                id: loginMessage
                text: ""
                visible: text !== ""
                color: "#f38ba8"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
            }

            // Username
            TextField {
                id: username
                Layout.fillWidth: true
                height: 42
                text: userModel.lastUser
                placeholderText: "Username"
                font.pixelSize: 14
                color: "#cdd6f4"
                leftPadding: 12; rightPadding: 12
                background: Rectangle {
                    color: "#1e1e2e"; radius: 6
                    border.color: username.activeFocus ? "#9f7cda" : "#3d3d5c"
                    border.width: 1
                }
                KeyNavigation.tab: password
                Keys.onReturnPressed: password.forceActiveFocus()
            }

            // Password
            TextField {
                id: password
                Layout.fillWidth: true
                height: 42
                placeholderText: "Password"
                echoMode: TextInput.Password
                font.pixelSize: 14
                color: "#cdd6f4"
                leftPadding: 12; rightPadding: 12
                background: Rectangle {
                    color: "#1e1e2e"; radius: 6
                    border.color: password.activeFocus ? "#9f7cda" : "#3d3d5c"
                    border.width: 1
                }
                KeyNavigation.tab: sessionBox
                Keys.onReturnPressed: loginBtn.doLogin()
            }

            // Session selector
            ComboBox {
                id: sessionBox
                Layout.fillWidth: true
                height: 38
                model: sessionModel
                textRole: "name"
                font.pixelSize: 13
                background: Rectangle {
                    color: "#1e1e2e"; radius: 6
                    border.color: sessionBox.activeFocus ? "#9f7cda" : "#3d3d5c"
                    border.width: 1
                }
                contentItem: Text {
                    leftPadding: 12
                    text: sessionBox.displayText
                    color: "#cdd6f4"
                    font: sessionBox.font
                    verticalAlignment: Text.AlignVCenter
                }
                KeyNavigation.tab: loginBtn
            }

            // Login button
            Button {
                id: loginBtn
                Layout.fillWidth: true
                height: 44
                text: "Login"
                font.pixelSize: 14
                font.weight: Font.Medium

                function doLogin() {
                    loginMessage.text = ""
                    sddm.login(username.text, password.text, sessionBox.currentIndex)
                }

                background: Rectangle {
                    color: loginBtn.pressed ? "#7c5cc4"
                         : loginBtn.hovered ? "#b48de8"
                         : "#9f7cda"
                    radius: 6
                    Behavior on color { ColorAnimation { duration: 100 } }
                }
                contentItem: Text {
                    text: loginBtn.text; font: loginBtn.font
                    color: "white"
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                onClicked: doLogin()
                Keys.onReturnPressed: doLogin()
            }

            Item { Layout.preferredHeight: 4 }
        }
    }

    // ── Power buttons (bottom-right) ──────────────────────────────────────────
    Row {
        anchors { bottom: parent.bottom; right: parent.right; margins: 20 }
        spacing: 8

        Button {
            id: suspendBtn
            text: "Suspend"; height: 32; font.pixelSize: 12
            background: Rectangle {
                color: suspendBtn.hovered ? "#3d3d5c" : "transparent"; radius: 4
                Behavior on color { ColorAnimation { duration: 100 } }
            }
            contentItem: Text {
                text: suspendBtn.text; font: suspendBtn.font; color: "#6c7086"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
            onClicked: sddm.suspend()
        }

        Button {
            id: rebootBtn
            text: "Reboot"; height: 32; font.pixelSize: 12
            background: Rectangle {
                color: rebootBtn.hovered ? "#3d3d5c" : "transparent"; radius: 4
                Behavior on color { ColorAnimation { duration: 100 } }
            }
            contentItem: Text {
                text: rebootBtn.text; font: rebootBtn.font; color: "#6c7086"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
            onClicked: sddm.reboot()
        }

        Button {
            id: shutdownBtn
            text: "Shutdown"; height: 32; font.pixelSize: 12
            background: Rectangle {
                color: shutdownBtn.hovered ? "#3d3d5c" : "transparent"; radius: 4
                Behavior on color { ColorAnimation { duration: 100 } }
            }
            contentItem: Text {
                text: shutdownBtn.text; font: shutdownBtn.font; color: "#6c7086"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
            onClicked: sddm.powerOff()
        }
    }

    // ── Initial focus ─────────────────────────────────────────────────────────
    Component.onCompleted: {
        if (username.text === "") username.forceActiveFocus()
        else password.forceActiveFocus()
    }
}
EOF

# =============================================================================
# SDDM configuration — activate the theme
# =============================================================================

cat > /etc/sddm.conf.d/theme.conf << 'EOF'
[Theme]
Current=gentoo

[General]
DefaultSession=xfce.desktop

[Wayland]
# Hide Wayland sessions — XFCE Wayland support is not stable
SessionDir=
EOF

echo "Theme files written to ${THEME_DIR}."

echo
echo "Gentoo SDDM theme installed."
echo "The login screen will use the Gentoo theme on next SDDM start."
echo "To apply now (will end your current session): systemctl restart sddm"
echo "To preview without logging out: sddm --test-mode --theme gentoo"
