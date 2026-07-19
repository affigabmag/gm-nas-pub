#!/usr/bin/env bash
# ============================================================================
# gmnas — the gm-nas control menu (swiss-army entry point for all helpers).
# Installed as /usr/local/bin/gmnas. Just run:  gmnas
# ============================================================================
export LANG=C.UTF-8   # so btop and box-drawing work

MENU_VER="01.33.20260719074412"   # bump when this menu changes

# --- colors (htop/btop-ish); disabled automatically when not a terminal -----
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
    R=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'
    CY=$'\e[38;5;44m'; GR=$'\e[38;5;83m'; YL=$'\e[38;5;227m'
    MG=$'\e[38;5;213m'; OR=$'\e[38;5;215m'; RD=$'\e[38;5;203m'; WH=$'\e[97m'; GY=$'\e[38;5;245m'
else
    R=; B=; DIM=; CY=; GR=; YL=; MG=; OR=; RD=; WH=; GY=
fi

H() { hostname 2>/dev/null; }
IP() { hostname -I 2>/dev/null | awk '{print $1}'; }
pause() { echo; read -rp "Press Enter to continue…" _; }
run() { echo "+ $*"; "$@"; }

RULE="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

header() {
    clear 2>/dev/null || true
    local ip prov; ip="$(IP)"; [ -z "$ip" ] && ip="<offline>"
    if [ -f /etc/homenas/provisioned ]; then prov="${GR}● online${R}"; else prov="${OR}● setup mode${R}"; fi
    printf "${CY}%s${R}\n" "$RULE"
    printf "  ${B}${WH}gm-nas${R} ${DIM}control menu${R}                              %b\n" "$prov"
    printf "  ${GY}Host${R} ${GR}%s.local${R}   ${GY}IP${R} ${GR}%s${R}\n" "$(H)" "$ip"
    printf "  ${GY}Seed${R} ${CY}%s${R}   ${GY}Menu${R} ${CY}v%s${R}\n" "$(cat /etc/gmnas-seed-version 2>/dev/null || echo '?')" "$MENU_VER"
    printf "${CY}%s${R}\n" "$RULE"
}

# item <key> <title> <desc>
item() { printf "   ${B}${YL}%s${R}  ${WH}%-26s${R} ${DIM}%s${R}\n" "$1" "$2" "$3"; }
# sec <label>
sec()  { printf "\n ${MG}${B}%s${R}\n" "$1"; }

while true; do
    header
    sec "INFO & LOGS"
    item a "Device info"        "login summary: IP, links, services"
    item b "Status / diag"      "gm-debug"
    item c "Setup log"          "the install/setup log"
    item d "Install error log"  "subiquity debug"
    item e "gm-nas logs"        "firstboot / join-wifi / reset / etc."
    item f "System monitor"     "btop"
    sec "NETWORK & SETUP"
    item g "Connect to WiFi"    "join-wifi"
    item h "First-time wizard"  "broadcast GMNas-Setup, set up from phone"
    sec "WEB & SERVICES"
    item i "Web links"          "Welcome / Cockpit / Terminal"
    item j "Restart web svcs"   "welcome + terminal"
    sec "INSTALL & UPDATE"
    item k "Install ALL"        "Cockpit/Tailscale/Samba/NFS/ttyd/welcome"
    item l "Update from GitHub" "gm-update, online"
    item m "Mount & view files" "mount a USB drive and list files"
    item n "Apply Ventoy edits" "offline update, no reinstall"
    sec "SHELL & POWER"
    item o "Open a shell"       ""
    printf "   ${B}${YL}p${R}  ${WH}Reboot${R}     ${B}${YL}q${R}  ${WH}Power off${R}     ${B}${RD}r${R}  ${WH}Quit${R}\n"
    printf "\n ${GR}Choose${R} ${DIM}(single key)${R} ${GR}❯${R} "
    read -rsn1 c; echo
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
        p|P) printf "${YL}Reboot the box now? [y/N] ${R}"; read -rsn1 yn; echo
             if [ "$yn" = y ] || [ "$yn" = Y ]; then sudo reboot; else echo "cancelled"; pause; fi ;;
        q|Q) printf "${RD}Power OFF the box? It will NOT come back without pressing the physical power button. [y/N] ${R}"; read -rsn1 yn; echo
             if [ "$yn" = y ] || [ "$yn" = Y ]; then sudo poweroff; else echo "cancelled"; pause; fi ;;
        r|R) exit 0 ;;
        *) ;;
    esac
done
