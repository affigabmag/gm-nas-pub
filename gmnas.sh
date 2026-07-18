#!/usr/bin/env bash
# ============================================================================
# gmnas — the gm-nas control menu (swiss-army entry point for all helpers).
# Installed as /usr/local/bin/gmnas. Just run:  gmnas
# ============================================================================
export LANG=C.UTF-8   # so btop and box-drawing work

MENU_VER="01.24.20260718220413"   # bump when this menu changes

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
    echo "  Menu : v$MENU_VER"
    echo "=========================================================="
}

while true; do
    header
    cat <<'MENU'
   1) Device info                 (login summary: IP, links, services)
   2) Status / diagnostics        (gm-debug)
   3) View the setup log
   4) Install error log           (subiquity debug)
   l) View gm-nas logs            (firstboot / join-wifi / reset / etc.)
   5) System monitor              (btop)
   6) Connect to a WiFi network   (join-wifi)
   7) First-time WiFi wizard      (broadcast GMNas-Setup, set up from phone)
   8) Web links                   (Welcome / Cockpit / Terminal)
   9) Restart web services        (welcome + terminal)
   a) Install ALL components      (Cockpit/Tailscale/Samba/NFS/ttyd/welcome)
   g) Update gm-nas from GitHub   (gm-update, online)
   m) Mount and view files        (mount a USB drive and list its files)
   v) Apply edits from Ventoy USB (offline update, no reinstall)
   s) Open a shell
   r) Reboot          p) Power off          q) Quit
MENU
    echo
    read -rsn1 -p "Choose: " c; echo
    case "$c" in
        1) sh /etc/update-motd.d/99-gmnas 2>/dev/null || echo "device info not available"; pause ;;
        2) command -v gm-debug >/dev/null && gm-debug || /usr/local/bin/gm-debug; pause ;;
        5) btop ;;
        6) read -rp "WiFi name (SSID) [home]: " s; s="${s:-home}"
           read -rsp "Password: " p; echo
           sudo join-wifi "$s" "$p" 2>/dev/null || sudo bash /usr/local/bin/join-wifi "$s" "$p"
           echo
           echo "A reboot is required to leave AP mode and connect to '$s'."
           echo "Reboot now? [y/N]"
           read -rsn1 yn; echo
           if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then sudo reboot; else pause; fi ;;
        7) echo "Starting the first-time WiFi wizard — the gm-nas will switch to"
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
        3) if [ -f /var/log/gm-nas-setup.log ]; then cat /var/log/gm-nas-setup.log; else echo "no setup log yet"; fi; pause ;;
        4) sudo grep -iE "command_[0-9]|fail|error" /var/log/installer/subiquity-server-debug.log 2>/dev/null | tail -30; pause ;;
        l|L) echo "--- /var/log/gm-nas/ ---"; ls -l /var/log/gm-nas/ 2>/dev/null || echo "(no gm-nas logs yet)"
             echo; echo "--- firstboot-wifi.log (last 50) ---"
             sudo tail -n 50 /var/log/gm-nas/firstboot-wifi.log 2>/dev/null || echo "(none)"; pause ;;
        8) h="$(H).local"
           echo "  Welcome  : http://$h"
           echo "  Cockpit  : https://$h:9090"
           echo "  Terminal : http://$h:7681"; pause ;;
        9) sudo systemctl restart gmnas-welcome.service ttyd.service cockpit.socket 2>/dev/null
           echo "restarted."; pause ;;
        a|A) sudo gm-install-all 2>/dev/null || sudo bash /usr/local/bin/gm-install-all; pause ;;
        g|G) sudo gm-update 2>/dev/null || sudo bash /usr/local/bin/gm-update; pause ;;
        m|M) sudo gm-usb mount 2>/dev/null || sudo bash /usr/local/bin/gm-usb mount; pause ;;
        v|V) sudo gm-usb apply 2>/dev/null || sudo bash /usr/local/bin/gm-usb apply; pause ;;
        s|S) echo "Type 'exit' to return to the menu."; bash ;;
        r|R) sudo reboot ;;
        p|P) sudo poweroff ;;
        q|Q) exit 0 ;;
        *) ;;
    esac
done
