#!/usr/bin/env bash
# ============================================================================
# gmnas — the gm-nas control menu (swiss-army entry point for all helpers).
# Installed as /usr/local/bin/gmnas. Just run:  gmnas
# ============================================================================
export LANG=C.UTF-8   # so btop and box-drawing work

MENU_VER="01.26.20260718223244"   # bump when this menu changes

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
   a) Device info                 (login summary: IP, links, services)
   b) Status / diagnostics        (gm-debug)
   c) View the setup log
   d) Install error log           (subiquity debug)
   e) View gm-nas logs            (firstboot / join-wifi / reset / etc.)
   f) System monitor              (btop)
   g) Connect to a WiFi network   (join-wifi)
   h) First-time WiFi wizard      (broadcast GMNas-Setup, set up from phone)
   i) Web links                   (Welcome / Cockpit / Terminal)
   j) Restart web services        (welcome + terminal)
   k) Install ALL components      (Cockpit/Tailscale/Samba/NFS/ttyd/welcome)
   l) Update gm-nas from GitHub   (gm-update, online)
   m) Mount and view files        (mount a USB drive and list its files)
   n) Apply edits from Ventoy USB (offline update, no reinstall)
   o) Open a shell
   p) Reboot          q) Power off          r) Quit
MENU
    echo
    read -rsn1 -p "Choose: " c; echo
    case "$c" in
        a|A) sh /etc/update-motd.d/99-gmnas 2>/dev/null || echo "device info not available"; pause ;;
        b|B) command -v gm-debug >/dev/null && gm-debug || /usr/local/bin/gm-debug; pause ;;
        c|C) if [ -f /var/log/gm-nas-setup.log ]; then cat /var/log/gm-nas-setup.log; else echo "no setup log yet"; fi; pause ;;
        d|D) sudo grep -iE "command_[0-9]|fail|error" /var/log/installer/subiquity-server-debug.log 2>/dev/null | tail -30; pause ;;
        e|E) echo "--- /var/log/gm-nas/ ---"; ls -l /var/log/gm-nas/ 2>/dev/null || echo "(no gm-nas logs yet)"
             echo; echo "--- firstboot-wifi.log (last 50) ---"
             sudo tail -n 50 /var/log/gm-nas/firstboot-wifi.log 2>/dev/null || echo "(none)"; pause ;;
        f|F) btop ;;
        g|G) read -rp "WiFi name (SSID) [home]: " s; s="${s:-home}"
           read -rsp "Password: " p; echo
           sudo join-wifi "$s" "$p" 2>/dev/null || sudo bash /usr/local/bin/join-wifi "$s" "$p"
           echo
           echo "A reboot is required to leave AP mode and connect to '$s'."
           echo "Reboot now? [y/N]"
           read -rsn1 yn; echo
           if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then sudo reboot; else pause; fi ;;
        h|H) echo "Starting the first-time WiFi wizard — the gm-nas will switch to"
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
        i|I) h="$(H).local"
           echo "  Welcome  : http://$h"
           echo "  Cockpit  : https://$h:9090"
           echo "  Terminal : http://$h:7681"; pause ;;
        j|J) sudo systemctl restart gmnas-welcome.service ttyd.service cockpit.socket 2>/dev/null
           echo "restarted."; pause ;;
        k|K) sudo gm-install-all 2>/dev/null || sudo bash /usr/local/bin/gm-install-all; pause ;;
        l|L) sudo gm-update 2>/dev/null || sudo bash /usr/local/bin/gm-update; pause ;;
        m|M) sudo gm-usb mount 2>/dev/null || sudo bash /usr/local/bin/gm-usb mount; pause ;;
        n|N) sudo gm-usb apply 2>/dev/null || sudo bash /usr/local/bin/gm-usb apply; pause ;;
        o|O) echo "Type 'exit' to return to the menu."; bash ;;
        p|P) sudo reboot ;;
        q|Q) sudo poweroff ;;
        r|R) exit 0 ;;
        *) ;;
    esac
done
