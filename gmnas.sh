#!/usr/bin/env bash
# ============================================================================
# gmnas — the gm-nas control menu (swiss-army entry point for all helpers).
# Installed as /usr/local/bin/gmnas. Just run:  gmnas
# ============================================================================
export LANG=C.UTF-8   # so btop and box-drawing work

MENU_VER="01.152.20260723002717"   # bump when this menu changes

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
# Robust "is the box online?" check. Does NOT rely on ICMP alone (many routers
# block ping to 8.8.8.8): tries ping, then a TCP connect to public DNS/HTTPS.
net_online() {
    ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && return 0
    ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && return 0
    timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null && return 0
    timeout 5 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53'  2>/dev/null && return 0
    return 1
}
# Run a gm-nas helper command, falling back to /usr/local/bin/<name> only if it
# genuinely isn't on PATH -- NOT on any non-zero exit from a real run. The old
# "sudo X || sudo bash /usr/local/bin/X" pattern re-ran the WHOLE command a
# second time whenever X succeeded but happened to exit non-zero (e.g. its last
# internal step returned 1) -- for reset-setup that meant restarting the setup
# AP mid-flight, racing itself and tearing the AP down within seconds.
run_helper() {
    local name="$1"; shift
    if command -v "$name" >/dev/null 2>&1; then
        sudo "$name" "$@"
    else
        sudo bash "/usr/local/bin/$name" "$@"
    fi
}
run() { echo "+ $*"; "$@"; }

# Show a command's output live inside a centered bordered box (dialog's
# --programbox), instead of it scrolling raw in the terminal. Falls back to
# plain output + pause if dialog isn't installed yet (e.g. offline, before
# Resume install). $1 = box title, rest = the command to run.
run_boxed() {
    local title="$1"; shift
    if command -v dialog >/dev/null 2>&1; then
        { "$@"; } 2>&1 | dialog --title " $title " --programbox "$(term_lines)" "$(term_cols)"
    else
        "$@"
        pause
    fi
}

# Full-proof prerequisite check for the First-time wizard (GMNas-Setup AP).
# The AP needs NetworkManager to own the WiFi device (wifi-connect + nmcli
# both go through it) + the wifi-connect binary/UI + the firstboot service.
# None of these exist on a fresh offline install until 'Resume install' has
# run. Instead of silently doing nothing when a piece is missing, list
# EXACTLY what's missing and how to fix it.
check_ap_prereqs() {
    local missing=()
    command -v nmcli >/dev/null 2>&1 || missing+=("network-manager (nmcli) not installed")
    systemctl is-active --quiet NetworkManager 2>/dev/null || missing+=("NetworkManager service not running")
    local wifi_state
    wifi_state="$(nmcli -t -f TYPE,STATE device 2>/dev/null | awk -F: '$1=="wifi"{print $2; exit}')"
    if [ -z "$wifi_state" ]; then
        missing+=("no WiFi device visible to NetworkManager at all")
    elif [ "$wifi_state" = "unmanaged" ]; then
        missing+=("WiFi device exists but NetworkManager doesn't manage it (still owned by networkd — run Resume install again to migrate it)")
    elif [ "$wifi_state" = "unavailable" ]; then
        missing+=("WiFi device exists but is unavailable to NetworkManager (state: unavailable — try a reboot)")
    fi
    [ -x /usr/local/lib/wifi-connect/wifi-connect ] || missing+=("wifi-connect binary not installed")
    [ -f /usr/local/lib/wifi-connect/ui/index.html ] || missing+=("setup-portal UI (index.html) not installed")
    [ -f /etc/systemd/system/homenas-firstboot.service ] || missing+=("homenas-firstboot.service not installed")
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "${RD}${B}Cannot start the First-time wizard — prerequisites not met:${R}"
        local m
        for m in "${missing[@]}"; do echo "  - $m"; done
        echo
        echo "Fix: run ${YL}Resume install (online)${R} or ${YL}Resume install (USB tether)${R} first,"
        echo "then try the First-time wizard again."
        return 1
    fi
    return 0
}

# Rule/footer are sized to the CURRENT terminal each render -- a fixed-length
# rule left a gap on wide terminals instead of spanning the full row.
term_cols() { tput cols 2>/dev/null || echo 60; }
term_lines() { tput lines 2>/dev/null || echo 24; }
rule() { local n; n=$(term_cols); printf -v RULE '%*s' "$n" ''; printf '%s' "${RULE// /━}"; }

STATS_LAST=0
STATS_TXT=""
# Cached CPU/mem/disk stats, refreshed at most once/minute -- render() runs on
# every keystroke (arrow nav), and top -bn1 takes ~1s, so recomputing every
# call would make navigation feel sluggish for a number that's stale anyway.
refresh_stats() {
    local now; now="$(date +%s)"
    if [ -n "$STATS_TXT" ] && [ $((now - STATS_LAST)) -lt 60 ]; then return; fi
    STATS_LAST="$now"
    local cpu mem disk
    cpu="$(top -bn1 2>/dev/null | awk '/Cpu\(s\)/{for(i=1;i<=NF;i++) if($i=="id,"){idle=$(i-1); gsub(/%/,"",idle); printf "%.0f%%", 100-idle}}')"
    mem="$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d/%dMB", $3,$2}')"
    disk="$(df -h --output=target,used,size 2>/dev/null | awk '$1=="/"||$1=="/srv/storage"{printf "%s %s/%s  ", $1,$2,$3}')"
    STATS_TXT="CPU ${cpu:-?}   MEM ${mem:-?}   DISK ${disk:-?}"
}

# Multi-statement action bodies, factored out so run_boxed (which takes a
# single command) can pipe their combined output into a bordered box.
act_a() { sh /etc/update-motd.d/99-gmnas 2>/dev/null || echo "device info not available"; }
act_c() { if [ -f /var/log/gm-nas-setup.log ]; then cat /var/log/gm-nas-setup.log; else echo "no setup log yet"; fi; }
act_e() {
    echo "--- /var/log/gm-nas/ ---"; ls -l /var/log/gm-nas/ 2>/dev/null || echo "(no gm-nas logs yet)"
    echo; echo "--- firstboot-wifi.log (last 50) ---"
    sudo tail -n 50 /var/log/gm-nas/firstboot-wifi.log 2>/dev/null || echo "(none)"
}
act_x() {
    echo "Checking internet…"; echo
    local ipaddr gw
    ipaddr="$(hostname -I 2>/dev/null | awk '{print $1}')"
    gw="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
    echo " This box IP : ${ipaddr:-<none>}"
    echo " Interfaces  : $(ip -brief link 2>/dev/null | awk '$1!="lo"{printf "%s(%s) ",$1,$2}')"
    echo " Gateway     : ${gw:-<none>}"
    if net_online; then
        echo " Internet    : ONLINE"
        if getent hosts github.com >/dev/null 2>&1; then
            echo " DNS         : OK (github.com resolves)"
        else
            echo " DNS         : FAIL (online but name lookup broken)"
        fi
    else
        echo " Internet    : OFFLINE (no route out)"
        [ -z "$gw" ] && echo "   note: no default gateway -- WiFi/DHCP may not have finished."
        echo "   -> Connect WiFi (menu: Connect to WiFi) or plug a phone USB tether."
    fi
}

header() {
    local ip prov; ip="$(IP)"; [ -z "$ip" ] && ip="<offline>"
    if [ -f /etc/homenas/provisioned ]; then prov="${GR}● online${R}"; else prov="${OR}● setup mode${R}"; fi
    refresh_stats
    printf "${CY}%s${R}${EL}\n" "$(rule)"
    printf "  ${B}${WH}gm-nas${R} ${DIM}control menu${R}                              %b${EL}\n" "$prov"
    printf "  ${GY}Host${R} ${GR}%s.local${R}   ${GY}IP${R} ${GR}%s${R}   ${GY}User${R} ${GR}%s${R}${EL}\n" "$(H)" "$ip" "$(whoami)"
    printf "  ${GY}Version${R} ${B}${GR}%s${R}${EL}\n" "$(cat /etc/gmnas-build-version 2>/dev/null || echo '?')"
    printf "  ${GY}%s${R}${EL}\n" "$STATS_TXT"
    printf "${CY}%s${R}${EL}\n" "$(rule)"
}

# item <key> <title> <desc>
item() { printf "   ${B}${YL}%s${R}  ${WH}%-26s${R} ${DIM}%s${R}${EL}\n" "$1" "$2" "$3"; }
# sec <label>
sec()  { printf "${EL}\n ${MG}${B}%s${R}${EL}\n" "$1"; }

# --- data-driven, arrow-navigable menu --------------------------------------
KEYS=(   a b c d e f z g x h w i j y s u k t l m n v o r p q )
TITLES=( "Device info" "Status / diag" "Setup log" "Install error log" "gm-nas logs" "System monitor" "Benchmark" \
         "Connect to WiFi" "Check internet" "First-time wizard" "Factory reset" "Web links" "Restart web svcs" \
         "Web browser (w3m)" "Web browser (lynx)" \
         "Auto-complete install" "Resume install (online)" \
         "Resume install (USB tether)" \
         "Update from GitHub" "Mount & view files" "Apply Ventoy edits" \
         "Boxed menu" "Open a shell" \
         "Reboot" "Power off" "Quit" )
DESCS=(  "login summary: IP, links, services" "gm-debug" "the install/setup log" "subiquity debug" \
         "firstboot / join-wifi / reset / etc." "btop" "CPU/RAM/disk score (Windows Experience Index style)" \
         "join-wifi" "ping test: is the box online?" \
         "broadcast GMNas-Setup, set up from phone" \
         "wipe account+shares+WiFi, replay first boot" "Welcome / Cockpit / Terminal" "welcome + terminal" \
         "w3m, terminal browser" "lynx, terminal browser" \
         "WiFi -> Resume install -> First-time wizard, one shot" \
         "download+install rest after WiFi (btop/samba/flask/cockpit/ttyd/welcome)" \
         "download rest over a phone USB tether (if WiFi unavailable)" \
         "gm-update, online" "mount a USB drive and list files" "offline update, no reinstall" \
         "same menu, everything inside dialog boxes" "shell as $(whoami)" \
         "restart the box" "shut down (needs power button)" "exit the menu" )
declare -A SECBEFORE=( [0]="INFO & LOGS" [7]="NETWORK & SETUP" [11]="WEB & SERVICES" \
                       [15]="INSTALL & UPDATE" [21]="SHELL & POWER" )
NUM=${#KEYS[@]}
SEL=0

render() {
    printf '\033[H'          # cursor home — redraw in place (no clear = no flash)
    header
    local i
    for ((i=0; i<NUM; i++)); do
        [ -n "${SECBEFORE[$i]:-}" ] && sec "${SECBEFORE[$i]}"
        if [ "$i" -eq "$SEL" ]; then
            printf "${HL}${B}   %s  %-26s %-40s${EL}${R}\n" "${KEYS[i]}" "${TITLES[i]}" "${DESCS[i]}"
        else
            item "${KEYS[i]}" "${TITLES[i]}" "${DESCS[i]}"
        fi
    done
    printf '\033[J'                          # clear any stale content down to the old footer position
    printf '\033[%d;1H' "$(term_lines)"       # pin the hint bar to the terminal's LAST row
    printf "${EL} ${GR}↑/↓${R} ${DIM}move${R}   ${GR}Enter${R} ${DIM}select${R}   ${GR}Esc/q${R} ${DIM}quit${R}   ${DIM}or a letter${R} ${GR}❯${R} "
}

# Runs the action for a given key. Factored out of the classic arrow-key
# loop so the all-dialog "Boxed menu" (see boxed_menu below) can dispatch
# through the exact same logic instead of duplicating it.
dispatch_action() {
    local c="$1"
    case "$c" in
        a|A) run_boxed "Device info" act_a ;;
        b|B) run_boxed "Status / diag" bash -c 'command -v gm-debug >/dev/null && gm-debug || /usr/local/bin/gm-debug' ;;
        c|C) run_boxed "Setup log" act_c ;;
        d|D) run_boxed "Install error log" sudo bash -c 'grep -iE "command_[0-9]|fail|error" /var/log/installer/subiquity-server-debug.log 2>/dev/null | tail -30' ;;
        e|E) run_boxed "gm-nas logs" act_e ;;
        f|F) btop ;;
        z|Z) run_boxed "Benchmark" run_helper gm-benchmark ;;
        g|G) read -rp "WiFi name (SSID) [home]: " s; s="${s:-home}"
           read -rsp "Password: " p; echo
           run_boxed "Connect to WiFi" run_helper join-wifi "$s" "$p"
           echo "A reboot is required to leave AP mode and connect to '$s'."
           echo "Reboot now? [y/N]"
           read -rsn1 yn; echo
           if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then sudo reboot; else pause; fi ;;
        x|X) run_boxed "Check internet" act_x ;;
        h|H) if ! check_ap_prereqs; then pause; return; fi
           echo "Starting the first-time WiFi wizard — the gm-nas will switch to"
           echo "setup mode (you'll lose this network connection). Continue? [y/N]"
           read -rsn1 yn; echo
           if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
             run_boxed "First-time wizard" run_helper reset-setup
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
        w|W) printf "${RD}${B}Factory reset${R} — this removes the current admin account, its\n"
           echo "Samba login, and all share definitions (defaults reseed fresh)."
           echo "Files under /srv/storage are KEPT. The gm-nas will then replay the"
           echo "WHOLE first-boot flow: WiFi setup AP -> welcome wizard -> shares."
           printf "${RD}Continue? [y/N]${R} "
           read -rsn1 yn; echo
           if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
             run_boxed "Factory reset" run_helper factory-reset
             echo "  ============ NOW ON YOUR PHONE ============"
             echo "   1) WiFi:     GMNas-Setup"
             echo "      Password: gmnas2026"
             echo "   2) Browser:  http://192.168.42.1"
             echo "   3) Pick your home WiFi + password, tap Connect"
             echo "   4) Complete the welcome wizard as a brand-new gm-nas"
             echo "  =========================================="
           else echo "cancelled."; fi
           pause ;;
        i|I) h="$(H).local"
           echo "  Welcome  : http://$h"
           echo "  Cockpit  : https://$h:9090"
           echo "  Terminal : http://$h:7681"; pause ;;
        j|J) run_boxed "Restart web svcs" sudo bash -c 'systemctl restart gmnas-welcome.service ttyd.service cockpit.socket 2>/dev/null; echo restarted.' ;;
        y|Y) if command -v w3m >/dev/null 2>&1; then
               read -rp "URL [https://lite.duckduckgo.com/lite]: " u; u="${u:-https://lite.duckduckgo.com/lite}"
               w3m -O UTF-8 "$u"
             else
               echo "w3m not installed -- run ${YL}Resume install (online)${R} first."
               pause
             fi ;;
        s|S) if command -v lynx >/dev/null 2>&1; then
               read -rp "URL [https://lite.duckduckgo.com/lite]: " u; u="${u:-https://lite.duckduckgo.com/lite}"
               lynx -display_charset=UTF-8 -assume_charset=UTF-8 "$u"
             else
               echo "lynx not installed -- run ${YL}Resume install (online)${R} first."
               pause
             fi ;;
        u|U) echo "${B}Auto-complete install${R} — WiFi -> Resume install -> First-time wizard"
           echo
           printf "${MG}${B}[Step 1/3] Connect to WiFi${R}\n"
           read -rp "WiFi name (SSID) [home]: " s; s="${s:-home}"
           read -rsp "Password: " p; echo
           run_boxed "Connect to WiFi" run_helper join-wifi "$s" "$p"
           echo "Waiting a few seconds for the connection to settle..."
           sleep 5
           echo
           printf "${MG}${B}[Step 2/3] Resume install${R}\n"
           if net_online; then
             echo "Internet OK -- resuming install online..."
             run_boxed "Resume install" run_helper gm-install-all
           else
             echo "No internet yet -- trying USB tether resume install..."
             run_boxed "Resume install (USB tether)" run_helper gm-resume-usb
           fi
           echo
           printf "${MG}${B}[Step 3/3] First-time wizard${R}\n"
           if ! check_ap_prereqs; then
             echo "Auto-complete stopped before the First-time wizard (see above)."
             pause; return
           fi
           echo "Starting the first-time WiFi wizard — the gm-nas will switch to"
           echo "setup mode (you'll lose this network connection). Continue? [y/N]"
           read -rsn1 yn; echo
           if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
             run_boxed "First-time wizard" run_helper reset-setup
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
        k|K) run_boxed "Resume install (online)" run_helper gm-install-all ;;
        t|T) run_boxed "Resume install (USB tether)" run_helper gm-resume-usb ;;
        l|L) run_boxed "Update from GitHub" run_helper gm-update ;;
        m|M) run_boxed "Mount & view files" run_helper gm-usb mount ;;
        n|N) run_boxed "Apply Ventoy edits" run_helper gm-usb apply ;;
        o|O) echo "Type 'exit' to return to the menu."; bash ;;
        r|R) printf "${YL}Reboot the box now? [y/N] ${R}"; read -rsn1 yn; echo
             if [ "$yn" = y ] || [ "$yn" = Y ]; then sudo reboot; else echo "cancelled"; pause; fi ;;
        p|P) printf "${RD}Power OFF the box? It will NOT come back without pressing the physical power button. [y/N] ${R}"; read -rsn1 yn; echo
             if [ "$yn" = y ] || [ "$yn" = Y ]; then sudo poweroff; else echo "cancelled"; pause; fi ;;
        q|Q) exit 0 ;;
        v|V) boxed_menu ;;
        *) ;;
    esac
}

# All-dialog alternative UI: same actions as the classic menu, but selection
# itself happens inside a dialog --menu box instead of the custom arrow-key
# renderer. Every action's output already goes through run_boxed, so once
# selection is boxed too, the whole experience stays inside dialog widgets.
# Falls back with a message if dialog isn't installed yet (offline phase).
# Plain-text (no ANSI colors -- dialog renders its own) version of the same
# host/IP/user/version/stats info the classic header() shows, used as the
# dialog --menu's body text so the boxed UI isn't missing that at-a-glance
# status the classic menu always has on screen.
boxed_header_text() {
    local ip prov
    ip="$(IP)"; [ -z "$ip" ] && ip="<offline>"
    if [ -f /etc/homenas/provisioned ]; then prov="online"; else prov="setup mode"; fi
    refresh_stats
    printf 'Host %s.local   IP %s   User %s   [%s]\nVersion %s\n%s\n' \
        "$(H)" "$ip" "$(whoami)" "$prov" \
        "$(cat /etc/gmnas-build-version 2>/dev/null || echo '?')" \
        "$STATS_TXT"
}

boxed_menu() {
    if ! command -v dialog >/dev/null 2>&1; then
        echo "dialog not installed -- run Resume install (online) first."
        pause
        return
    fi
    while true; do
        local args=(--title " gm-nas control menu " --menu "$(boxed_header_text)" "$(term_lines)" "$(term_cols)" $((NUM - 1)))
        local i
        for ((i=0; i<NUM; i++)); do
            [ "${KEYS[i]}" = v ] && continue   # don't nest "Boxed menu" inside itself
            args+=("${KEYS[i]}" "${TITLES[i]} -- ${DESCS[i]}")
        done
        local choice
        choice="$(dialog "${args[@]}" --stdout)" || return   # Cancel/Esc -> back to classic menu
        printf '\033[2J\033[H'
        dispatch_action "$choice"
    done
}

# clear the screen ONCE on entry; render() then redraws in place each keystroke
printf '\033[2J\033[H'
# NOTE: no upfront "sudo -v" here -- it would prompt for a password before the
# menu even shows. Actions that need root call sudo themselves (and sudo then
# caches the credential for a few minutes).
while true; do
    render
    # -t 60: wake on its own every minute (even with no keypress) so the
    # CPU/mem/disk stats line actually refreshes while the menu sits idle,
    # not just when the user happens to press a key.
    if ! IFS= read -rsn1 -t 60 k; then continue; fi
    if [ "$k" = $'\e' ]; then IFS= read -rsn2 -t 0.05 rest; k="$k$rest"; fi
    case "$k" in
        $'\e[A'|$'\eOA') SEL=$(( (SEL - 1 + NUM) % NUM )); continue ;;
        $'\e[B'|$'\eOB') SEL=$(( (SEL + 1) % NUM )); continue ;;
        $'\e') echo; exit 0 ;;      # bare Esc -> quit (same as q)
        "")  c="${KEYS[$SEL]}" ;;   # Enter -> run the highlighted item
        *)   c="$k" ;;              # letter -> run it directly
    esac
    printf '\033[2J\033[H'   # full clear before running the action -- long
                             # output otherwise scrolls the old menu content
                             # up and off-screen instead of starting fresh
    dispatch_action "$c"
done
