#!/usr/bin/env bash
# Configure lightdm to auto-login the invoking user into an XFCE session on
# :0, so the noVNC stack (post/64-novnc.sh) has a live desktop to share
# without an interactive greeter login. Idempotent.
#
# NB: this only brings up the *desktop*. x11vnc still won't share it until a
# VNC password exists — set one with `sudo x11vnc -storepasswd
# /etc/x11vnc.passwd` (post/64-novnc.sh keeps x11vnc.service enabled but
# stopped until then, so we never expose an unauthenticated desktop).
set -euo pipefail

USER="${USER:-$(id -un)}"

# lightdm ships its binary in /usr/sbin, which isn't always on a non-login
# PATH; check both.
if ! command -v lightdm >/dev/null 2>&1 && [ ! -x /usr/sbin/lightdm ]; then
    echo "post/65-xfce-autologin: lightdm not installed; skipping"
    exit 0
fi

conf_dir="/etc/lightdm/lightdm.conf.d"
conf="$conf_dir/50-autologin.conf"

sudo install -d -m 0755 "$conf_dir"
sudo tee "$conf" >/dev/null <<EOF
[Seat:*]
autologin-user=$USER
autologin-session=xfce
EOF
echo "post/65-xfce-autologin: autologin $USER -> xfce session ($conf)"

# On Debian, /etc/pam.d/lightdm-autologin gates passwordless autologin on
# membership in the 'nopasswdlogin' group; without it lightdm silently falls
# back to the greeter. Create the group if absent and add the user.
if ! getent group nopasswdlogin >/dev/null; then
    sudo groupadd nopasswdlogin
fi
if id -nG "$USER" | tr ' ' '\n' | grep -qx nopasswdlogin; then
    echo "post/65-xfce-autologin: $USER already in nopasswdlogin group"
else
    sudo usermod -aG nopasswdlogin "$USER"
    echo "post/65-xfce-autologin: added $USER to nopasswdlogin group"
fi

# Enable the display manager so :0 comes up on boot. Don't force-start it
# here — during an offline/cloud-init install the graphics stack may not be
# ready; a reboot (or `sudo systemctl start lightdm`) brings it up cleanly.
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    sudo systemctl enable lightdm >/dev/null 2>&1 || true
    echo "post/65-xfce-autologin: lightdm enabled (starts X :0 on next boot)"
else
    echo "post/65-xfce-autologin: systemd not active; enable lightdm manually"
fi
