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
   1) Status / diagnostics        (gm-debug)
   2) System monitor              (btop)
   3) Connect to a WiFi network   (join-wifi)
   4) Show the setup WiFi again   (GMNas-Setup AP)
   5) View the setup log
   6) Web links (Welcome / Cockpit / Terminal)
   7) Restart web services        (welcome + terminal)
   8) Update gm-nas from GitHub   (gm-update)
   9) Open a shell
   r) Reboot          p) Power off          q) Quit
MENU
    echo
    read -rp "Choose: " c
    case "$c" in
        1) command -v gm-debug >/dev/null && gm-debug || /usr/local/bin/gm-debug; pause ;;
        2) btop ;;
        3) read -rp "WiFi name (SSID) [home]: " s; s="${s:-home}"
           read -rsp "Password: " p; echo
           sudo join-wifi "$s" "$p" 2>/dev/null || sudo bash /usr/local/bin/join-wifi "$s" "$p"; pause ;;
        4) sudo reset-setup 2>/dev/null || sudo bash /usr/local/bin/reset-setup
           echo; echo "Connect a phone to WiFi 'GMNas-Setup' (password: gmnas2026)"; pause ;;
        5) less /var/log/gm-nas-setup.log 2>/dev/null || echo "no log yet"; [ -f /var/log/gm-nas-setup.log ] || pause ;;
        6) h="$(H).local"
           echo "  Welcome  : http://$h"
           echo "  Cockpit  : https://$h:9090"
           echo "  Terminal : http://$h:7681"; pause ;;
        7) sudo systemctl restart gmnas-welcome.service ttyd.service cockpit.socket 2>/dev/null
           echo "restarted."; pause ;;
        8) sudo gm-update 2>/dev/null || sudo bash /usr/local/bin/gm-update; pause ;;
        9) echo "Type 'exit' to return to the menu."; bash ;;
        r|R) sudo reboot ;;
        p|P) sudo poweroff ;;
        q|Q) exit 0 ;;
        *) ;;
    esac
done
