#!/usr/bin/env bash
# ============================================================================
# gmnas — the gm-nas control menu (swiss-army entry point for all helpers).
# Installed as /usr/local/bin/gmnas. Just run:  gmnas
# ============================================================================
export LANG=C.UTF-8   # so btop and box-drawing work

H() { hostname 2>/dev/null; }
IP() { hostname -I 2>/dev/null | awk '{print $1}'; }
pause() { echo; read -rp "Press Enter to continue…" _; }
run() { echo "+ $*"; "$@"; }

header() {
    clear 2>/dev/null || true
    local ip; ip="$(IP)"; [ -z "$ip" ] && ip="<offline>"
    echo "=================== gm-nas control menu ==================="
    echo "  Host : $(H).local        IP : $ip"
    echo "  Seed : $(cat /etc/gmnas-seed-version 2>/dev/null || echo '?')"
    echo "=========================================================="
}

while true; do
    header
    cat <<'MENU'
   0) Device info                 (login summary: IP, links, services)
   1) Status / diagnostics        (gm-debug)
   5) View the setup log
   i) Install error log           (subiquity debug)
   2) System monitor              (btop)
   3) Connect to a WiFi network   (join-wifi)
   4) First-time WiFi wizard      (broadcast GMNas-Setup, set up from phone)
   6) Web links (Welcome / Cockpit / Terminal)
   7) Restart web services        (welcome + terminal)
   a) Install ALL components      (Cockpit/Tailscale/Samba/NFS/ttyd/welcome)
   8) Update gm-nas from GitHub   (gm-update, online)
   m) Mount and view files        (mount a USB drive and list its files)
   u) Apply edits from Ventoy USB (offline update, no reinstall)
   9) Open a shell
   r) Reboot          p) Power off          q) Quit
MENU
    echo
    read -rsn1 -p "Choose: " c; echo
    case "$c" in
        0) sh /etc/update-motd.d/99-gmnas 2>/dev/null || echo "device info not available"; pause ;;
        1) command -v gm-debug >/dev/null && gm-debug || /usr/local/bin/gm-debug; pause ;;
        2) btop ;;
        3) read -rp "WiFi name (SSID) [home]: " s; s="${s:-home}"
           read -rsp "Password: " p; echo
           sudo join-wifi "$s" "$p" 2>/dev/null || sudo bash /usr/local/bin/join-wifi "$s" "$p"
           echo
           echo "A reboot is required to leave AP mode and connect to '$s'."
           echo "Reboot now? [y/N]"
           read -rsn1 yn; echo
           if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then sudo reboot; else pause; fi ;;
        4) echo "Starting the first-time WiFi wizard — the gm-nas will switch to"
           echo "setup mode (you'll lose this network connection). Continue? [y/N]"
           read -rsn1 yn; echo
           if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
             sudo reset-setup 2>/dev/null || sudo bash /usr/local/bin/reset-setup
             echo
             echo "  ============ NOW ON YOUR PHONE ============"
             echo "   1) WiFi:     GMNas-Setup"
             echo "      Password: gmnas2026"
             echo "   2) Browser:  http://192.168.42.1"
             echo "   3) Pick your home WiFi + password, tap Connect"
             echo
             echo "   The gm-nas joins it, then reboots on the new WiFi."
             echo "  =========================================="
           else echo "cancelled."; fi
           pause ;;
        5) if [ -f /var/log/gm-nas-setup.log ]; then cat /var/log/gm-nas-setup.log; else echo "no setup log yet"; fi; pause ;;
        i|I) sudo grep -iE "command_[0-9]|fail|error" /var/log/installer/subiquity-server-debug.log 2>/dev/null | tail -30; pause ;;
        6) h="$(H).local"
           echo "  Welcome  : http://$h"
           echo "  Cockpit  : https://$h:9090"
           echo "  Terminal : http://$h:7681"; pause ;;
        7) sudo systemctl restart gmnas-welcome.service ttyd.service cockpit.socket 2>/dev/null
           echo "restarted."; pause ;;
        a|A) sudo gm-install-all 2>/dev/null || sudo bash /usr/local/bin/gm-install-all; pause ;;
        8) sudo gm-update 2>/dev/null || sudo bash /usr/local/bin/gm-update; pause ;;
        m|M) sudo gm-usb mount 2>/dev/null || sudo bash /usr/local/bin/gm-usb mount; pause ;;
        u|U) sudo gm-usb apply 2>/dev/null || sudo bash /usr/local/bin/gm-usb apply; pause ;;
        9) echo "Type 'exit' to return to the menu."; bash ;;
        r|R) sudo reboot ;;
        p|P) sudo poweroff ;;
        q|Q) exit 0 ;;
        *) ;;
    esac
done
