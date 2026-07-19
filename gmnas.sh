#!/usr/bin/env bash
# ============================================================================
# gmnas — the gm-nas control menu (swiss-army entry point for all helpers).
# Installed as /usr/local/bin/gmnas. Just run:  gmnas
# ============================================================================
export LANG=C.UTF-8   # so btop and box-drawing work

MENU_VER="01.55.20260719124414"   # bump when this menu changes

# --- colors (htop/btop-ish); disabled automatically when not a terminal -----
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
    R=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'
    CY=$'\e[38;5;44m'; GR=$'\e[38;5;83m'; YL=$'\e[38;5;227m'
    MG=$'\e[38;5;213m'; OR=$'\e[38;5;215m'; RD=$'\e[38;5;203m'; WH=$'\e[97m'; GY=$'\e[38;5;245m'
    HL=$'\e[48;2;102;102;102m\e[38;2;255;255;255m'   # highlight: #666666 gray bg, #ffffff white text
    EL=$'\e[K'                       # erase to end of line (flicker-free redraw)
else
    R=; B=; DIM=; CY=; GR=; YL=; MG=; OR=; RD=; WH=; GY=; HL=; EL=
fi

H() { hostname 2>/dev/null; }
IP() { hostname -I 2>/dev/null | awk '{print $1}'; }
pause() { echo; read -rp "Press Enter to continue…" _; }
run() { echo "+ $*"; "$@"; }

RULE="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

header() {
    local ip prov; ip="$(IP)"; [ -z "$ip" ] && ip="<offline>"
    if [ -f /etc/homenas/provisioned ]; then prov="${GR}● online${R}"; else prov="${OR}● setup mode${R}"; fi
    printf "${CY}%s${R}${EL}\n" "$RULE"
    printf "  ${B}${WH}gm-nas${R} ${DIM}control menu${R}                              %b${EL}\n" "$prov"
    printf "  ${GY}Host${R} ${GR}%s.local${R}   ${GY}IP${R} ${GR}%s${R}   ${GY}User${R} ${GR}%s${R}${EL}\n" "$(H)" "$ip" "$(whoami)"
    printf "  ${GY}Seed${R} ${CY}%s${R}   ${GY}Menu${R} ${CY}v%s${R}${EL}\n" "$(cat /etc/gmnas-seed-version 2>/dev/null || echo '?')" "$MENU_VER"
    printf "${CY}%s${R}${EL}\n" "$RULE"
}

# item <key> <title> <desc>
item() { printf "   ${B}${YL}%s${R}  ${WH}%-26s${R} ${DIM}%s${R}${EL}\n" "$1" "$2" "$3"; }
# sec <label>
sec()  { printf "${EL}\n ${MG}${B}%s${R}${EL}\n" "$1"; }

# --- data-driven, arrow-navigable menu --------------------------------------
KEYS=(   a b c d e f g h i j k l m n o r p q )
TITLES=( "Device info" "Status / diag" "Setup log" "Install error log" "gm-nas logs" "System monitor" \
         "Connect to WiFi" "First-time wizard" "Web links" "Restart web svcs" "Install ALL" \
         "Update from GitHub" "Mount & view files" "Apply Ventoy edits" "Open a shell" \
         "Reboot" "Power off" "Quit" )
DESCS=(  "login summary: IP, links, services" "gm-debug" "the install/setup log" "subiquity debug" \
         "firstboot / join-wifi / reset / etc." "btop" "join-wifi" "broadcast GMNas-Setup, set up from phone" \
         "Welcome / Cockpit / Terminal" "welcome + terminal" "Cockpit/Tailscale/Samba/NFS/ttyd/welcome" \
         "gm-update, online" "mount a USB drive and list files" "offline update, no reinstall" \
         "shell as $(whoami)" "restart the box" "shut down (needs power button)" "exit the menu" )
declare -A SECBEFORE=( [0]="INFO & LOGS" [6]="NETWORK & SETUP" [8]="WEB & SERVICES" \
                       [10]="INSTALL & UPDATE" [14]="SHELL & POWER" )
NUM=${#KEYS[@]}
SEL=0

render() {
    printf '\033[H'          # cursor home — redraw in place (no clear = no flash)
    header
    local i
    for ((i=0; i<NUM; i++)); do
        [ -n "${SECBEFORE[$i]:-}" ] && sec "${SECBEFORE[$i]}"
        if [ "$i" -eq "$SEL" ]; then
            printf "  ${HL}${B} %s  %-26s %-40s ${R}${EL}\n" "${KEYS[i]}" "${TITLES[i]}" "${DESCS[i]}"
        else
            item "${KEYS[i]}" "${TITLES[i]}" "${DESCS[i]}"
        fi
    done
    printf "${EL}\n ${GR}↑/↓${R} ${DIM}move${R}   ${GR}Enter${R} ${DIM}select${R}   ${GR}Esc/q${R} ${DIM}quit${R}   ${DIM}or a letter${R} ${GR}❯${R} \033[J"
}

# clear the screen ONCE on entry; render() then redraws in place each keystroke
printf '\033[2J\033[H'
while true; do
    render
    IFS= read -rsn1 k
    if [ "$k" = $'\e' ]; then IFS= read -rsn2 -t 0.05 rest; k="$k$rest"; fi
    case "$k" in
        $'\e[A'|$'\eOA') SEL=$(( (SEL - 1 + NUM) % NUM )); continue ;;
        $'\e[B'|$'\eOB') SEL=$(( (SEL + 1) % NUM )); continue ;;
        $'\e') echo; exit 0 ;;      # bare Esc -> quit (same as q)
        "")  c="${KEYS[$SEL]}" ;;   # Enter -> run the highlighted item
        *)   c="$k" ;;              # letter -> run it directly
    esac
    echo
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
        r|R) printf "${YL}Reboot the box now? [y/N] ${R}"; read -rsn1 yn; echo
             if [ "$yn" = y ] || [ "$yn" = Y ]; then sudo reboot; else echo "cancelled"; pause; fi ;;
        p|P) printf "${RD}Power OFF the box? It will NOT come back without pressing the physical power button. [y/N] ${R}"; read -rsn1 yn; echo
             if [ "$yn" = y ] || [ "$yn" = Y ]; then sudo poweroff; else echo "cancelled"; pause; fi ;;
        q|Q) exit 0 ;;
        *) ;;
    esac
done
