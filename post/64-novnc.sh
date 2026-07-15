#!/usr/bin/env bash
# Browser remote desktop for the live XFCE (X11) session via the noVNC
# stack: x11vnc shares :0 over VNC, websockify bridges it to a browser and
# serves the noVNC HTML5 client.
#
#   browser (noVNC) --websocket--> websockify :6080 --tcp/RFB--> x11vnc :5900 --> :0
#
# Installs two systemd system units so it survives reboot. The websockify
# proxy is always enabled (it's harmless until x11vnc is up). x11vnc is
# enabled ONLY once a VNC password exists at /etc/x11vnc.passwd, so we
# never expose an unauthenticated desktop by default.
#
# Idempotent: rewrites the units and re-reconciles enable state each run.
set -euo pipefail

VNC_PASSWD="/etc/x11vnc.passwd"
NOVNC_PORT="6080"

if ! command -v systemctl >/dev/null 2>&1; then
    echo "post/64-novnc: systemctl not present; skipping" >&2
    exit 0
fi
if ! systemctl is-system-running >/dev/null 2>&1 && [ ! -d /run/systemd/system ]; then
    echo "post/64-novnc: systemd not running; install units manually" >&2
    exit 0
fi

# x11vnc shares the live :0 session. -auth guess locates the session's
# Xauthority (works with lightdm/XFCE); -loop reconnects across logout/
# login; -localhost keeps VNC itself reachable only via the local proxy.
sudo tee /etc/systemd/system/x11vnc.service >/dev/null <<EOF
[Unit]
Description=x11vnc: share the live X :0 desktop over VNC (localhost only)
After=display-manager.service
Wants=display-manager.service

[Service]
Type=simple
ExecStart=/usr/bin/x11vnc -display :0 -auth guess -rfbauth ${VNC_PASSWD} \\
    -localhost -forever -loop -shared -noxdamage -o /var/log/x11vnc.log
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# websockify serves the noVNC client from /usr/share/novnc and proxies the
# browser's WebSocket to the local VNC port. Bound on all interfaces so you
# can reach it from another machine; the x11vnc password is the gate. Put
# TLS on it (--cert=...) or firewall ${NOVNC_PORT} on hostile networks.
sudo tee /etc/systemd/system/novnc.service >/dev/null <<EOF
[Unit]
Description=noVNC: HTML5 VNC client + websockify bridge to x11vnc
After=network-online.target x11vnc.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/websockify --web /usr/share/novnc ${NOVNC_PORT} localhost:5900
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now novnc.service

if sudo test -f "${VNC_PASSWD}"; then
    sudo systemctl enable --now x11vnc.service
    echo "post/64-novnc: desktop at http://<host>:${NOVNC_PORT}/vnc.html"
else
    sudo systemctl enable x11vnc.service >/dev/null 2>&1 || true
    echo "post/64-novnc: set a VNC password, then start x11vnc:" >&2
    echo "    sudo x11vnc -storepasswd ${VNC_PASSWD}" >&2
    echo "    sudo systemctl start x11vnc.service" >&2
    echo "  then browse to http://<host>:${NOVNC_PORT}/vnc.html" >&2
fi
