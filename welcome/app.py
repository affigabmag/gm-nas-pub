#!/usr/bin/env python3
# ============================================================================
# gm-nas welcome app  (Step 4)
# ----------------------------------------------------------------------------
# Lightweight post-setup web UI, served on http://my-gmnas.local (port 80).
# Runs as root via gmnas-welcome.service so it can set the admin password,
# install apps, and manage Samba shares.
#
#   - Set the admin password (b1 flow): chpasswd for `gmnas`, then remove the
#     /etc/homenas/password-not-set flag (unlocks Cockpit login).
#   - Apps: Cockpit auto-installs in the background on first post-setup load;
#     Tailscale installs on-demand (downloaded + installed at the tap) and can
#     then be connected (prints a login link the user opens).
#   - Quick links: Cockpit (:9090) and the browser terminal (ttyd :7681).
#   - Shares: list folders under /srv/storage, create a folder + Samba share.
#
# No secrets in this file — safe in the public repo.
# ============================================================================
import os
import re
import shutil
import subprocess
from html import escape
from flask import Flask, request, redirect, render_template_string, jsonify

app = Flask(__name__)

STORAGE = "/srv/storage"
PW_FLAG = "/etc/homenas/password-not-set"
ADMIN_USER = "gmnas"
SMB_CONF = "/etc/samba/smb.conf"
SMB_MARK = "# --- gm-nas managed shares ---"

# Background-install bookkeeping (markers + logs).
RUN_DIR = "/run/gmnas"
LOG_DIR = "/var/log/gm-nas"

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>gm-nas</title>
<style>
 :root{--bg:#0f172a;--card:#1e293b;--fg:#f1f5f9;--muted:#94a3b8;--accent:#38bdf8;
  --accent-fg:#04263a;--border:#334155;--ok:#4ade80;--danger:#f87171;--warn:#fbbf24}
 *{box-sizing:border-box} body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
  background:var(--bg);color:var(--fg);padding:16px}
 .wrap{max-width:720px;margin:0 auto}
 header{display:flex;flex-wrap:wrap;align-items:center;justify-content:center;gap:8px 10px;margin:20px 0}
 .logo{width:44px;height:44px;margin:0;border-radius:12px;flex:none;
  background:linear-gradient(135deg,var(--accent),#6366f1);display:flex;align-items:center;
  justify-content:center;font-size:26px;font-weight:700;color:var(--accent-fg)}
 h1{font-size:20px;margin:0} .sub{color:var(--muted);margin:0}
 .card{background:var(--card);border:1px solid var(--border);border-radius:16px;padding:20px;margin-top:16px}
 .card h2{font-size:16px;margin:0 0 12px}
 label{display:block;font-size:13px;color:var(--muted);margin:12px 0 6px}
 input{width:100%;font-size:16px;border-radius:10px;border:1px solid var(--border);
  padding:12px;background:#0b1220;color:var(--fg)}
 button{margin-top:16px;width:100%;background:var(--accent);color:var(--accent-fg);font-weight:700;
  border:none;border-radius:10px;padding:14px;font-size:15px;cursor:pointer}
 .links{display:grid;grid-template-columns:1fr 1fr;gap:12px}
 .links a{display:block;text-align:center;text-decoration:none;color:var(--fg);
  background:#0b1220;border:1px solid var(--border);border-radius:10px;padding:16px;font-weight:500}
 .msg{margin-top:12px;font-size:14px} .ok{color:var(--ok)} .err{color:var(--danger)}
 table{width:100%;border-collapse:collapse;font-size:14px} td{padding:6px 0;border-top:1px solid var(--border)}
 .hint{font-size:12px;color:var(--muted);margin-top:6px}
 .pass-wrap{position:relative} .pass-wrap input{padding-right:46px}
 .eye{position:absolute;right:6px;top:50%;transform:translateY(-50%);background:none;border:none;
  cursor:pointer;font-size:18px;padding:6px 8px;line-height:1;opacity:.7;width:auto;margin:0}
 .eye:hover,.eye.on{opacity:1}
 .ver{text-align:center;color:var(--muted);font-size:11px;margin:22px 0 8px}
 .netstrip{display:inline-flex;flex-wrap:wrap;align-items:center;justify-content:center;gap:4px 8px;
  margin:0;font-size:13px;padding:6px 14px;border-radius:999px;background:var(--card);border:1px solid var(--border)}
 .netstrip .sep{opacity:.7;font-size:11px}
 .dot{width:9px;height:9px;border-radius:50%;display:inline-block}
 .dot.ok{background:var(--ok);box-shadow:0 0 8px var(--ok)}
 .dot.off{background:var(--danger)}
 .dot.warn{background:var(--warn)}
 .netstrip .ip{color:var(--muted);font-size:12px}
 .hver{color:var(--muted);font-size:11px;margin:0}
 .danger-btn{background:var(--danger);color:#3a0a0a}
 .modal-bg{position:fixed;inset:0;background:rgba(0,0,0,.65);display:none;
  align-items:center;justify-content:center;padding:20px;z-index:50}
 .modal-bg.open{display:flex}
 .modal{background:var(--card);border:1px solid var(--border);border-radius:16px;
  padding:24px;max-width:420px;width:100%}
 .modal h3{margin:0 0 12px;font-size:18px}
 .modal p{color:var(--muted);font-size:14px;line-height:1.7;margin:0}
 .modal ul{color:var(--muted);font-size:14px;line-height:1.8;margin:10px 0;padding-left:18px}
 .modal-actions{display:flex;gap:12px;margin-top:22px}
 .modal-actions>*{flex:1;margin:0}
 .btn-cancel{background:#0b1220;color:var(--fg);border:1px solid var(--border)}
 .app{display:flex;align-items:center;gap:12px;padding:12px 0;border-top:1px solid var(--border)}
 .app:first-of-type{border-top:none}
 .app .name{font-weight:600;flex:0 0 auto} .app .desc{color:var(--muted);font-size:12px}
 .app .grow{flex:1 1 auto}
 .badge{font-size:12px;font-weight:700;padding:4px 10px;border-radius:999px;white-space:nowrap}
 .b-ok{background:rgba(74,222,128,.15);color:var(--ok)}
 .b-busy{background:rgba(251,191,36,.15);color:var(--warn)}
 .b-off{background:rgba(148,163,184,.15);color:var(--muted)}
 form.inline{margin:0} form.inline button{margin:0;width:auto;padding:10px 14px;font-size:13px}
 a.linkbtn{display:inline-block;background:var(--accent);color:var(--accent-fg);font-weight:700;
  text-decoration:none;border-radius:8px;padding:10px 14px;font-size:13px}
</style></head><body><div class="wrap">
 <header><div class="logo"><svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="#04263a" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="7" rx="1.5"/><rect x="3" y="13" width="18" height="7" rx="1.5"/><circle cx="6.6" cy="7.5" r="0.9" fill="#04263a" stroke="none"/><circle cx="6.6" cy="16.5" r="0.9" fill="#04263a" stroke="none"/><line x1="9.5" y1="7.5" x2="17.5" y2="7.5"/><line x1="9.5" y1="16.5" x2="17.5" y2="16.5"/></svg></div><h1>Welcome to your gm-nas</h1>
  <p class="sub">{{ host }}</p>
  <div id="netstrip" class="netstrip">
    <span id="netdot" class="dot {{ 'ok' if online else 'off' }}"></span>
    <span id="nettext">{{ 'Online' if online else 'Offline' }}</span>
    <span id="netip" class="ip">{{ ip }}</span>
    <span class="ip sep">· {{ version }}</span>
  </div></header>

 {% if msg %}<div class="card"><div class="msg {{ msgcls }}">{{ msg }}</div></div>{% endif %}

 {% if password_not_set %}
 <div class="card"><h2>1. Create your admin account</h2>
  <p class="hint">Your sign-in for Cockpit and admin tasks. Pick any username you like.</p>
  <form method="post" action="/account">
   <label>Username</label>
   <input name="username" required pattern="[a-z_][a-z0-9_-]{0,31}" autocapitalize="none"
          autocomplete="off" placeholder="e.g. john">
   <div class="hint">Lowercase letters, digits, <b>-</b> and <b>_</b>. Must start with a letter.</div>
   <label>New password</label>
   <div class="pass-wrap"><input type="password" name="pw" class="pw" required minlength="8">
    <button type="button" class="eye" aria-label="Show password">👁</button></div>
   <label>Confirm password</label>
   <div class="pass-wrap"><input type="password" name="pw2" class="pw" required minlength="8">
    <button type="button" class="eye" aria-label="Show password">👁</button></div>
   <button type="submit">Create admin account</button>
  </form></div>
 {% endif %}

 <div class="card"><h2>Apps</h2>
  <!-- Cockpit: auto-installs in the background after setup -->
  <div class="app">
   <span class="name">Cockpit</span>
   <span class="grow"><span class="desc">Web admin: system, storage, logs, updates</span></span>
   {% if cockpit == 'ready' %}<a class="linkbtn" href="https://{{ host }}:9090" target="_blank">Open ↗</a>
   {% elif cockpit == 'busy' %}<span class="badge b-busy">Installing…</span>
   {% else %}
     <form class="inline" method="post" action="/install/cockpit"><button>Install</button></form>
   {% endif %}
  </div>
  <!-- Tailscale: on-demand install, then connect for a login link -->
  <div class="app">
   <span class="name">Tailscale</span>
   <span class="grow"><span class="desc">Secure remote access from anywhere (VPN)</span></span>
   {% if tailscale == 'up' %}<span class="badge b-ok">Connected</span>
   {% elif ts_login_url %}<span class="badge b-busy">Waiting for sign-in ↓</span>
   {% elif tailscale == 'ready' %}
     <form class="inline" method="post" action="/tailscale/up"><button>Connect</button></form>
   {% elif tailscale == 'busy' %}<span class="badge b-busy">Installing…</span>
   {% else %}
     <form class="inline" method="post" action="/install/tailscale"><button>Install</button></form>
   {% endif %}
  </div>
  {% if ts_login_url %}
  <p class="hint">Tailscale needs a one-time sign-in. Open this link and log in:</p>
  <a class="linkbtn" href="{{ ts_login_url }}" target="_blank">Sign in to Tailscale ↗</a>
  {% endif %}
  {% if busy %}<p class="hint">Installing… this page refreshes automatically.</p>{% endif %}
 </div>

 <div class="card"><h2>Manage</h2>
  <div class="links">
   <a href="https://{{ host }}:9090" target="_blank">Cockpit admin ↗</a>
   <a href="http://{{ host }}:7681" target="_blank">Terminal ↗</a>
  </div>
  <p class="hint">Cockpit: system, storage, logs, updates. Terminal: a shell in your browser.</p>
 </div>

 <div class="card"><h2>File shares</h2>
  {% if shares %}
  <table>{% for s in shares %}<tr><td>📁 {{ s }}</td>
   <td style="text-align:right"><code>\\\\{{ host }}\\{{ s }}</code></td></tr>{% endfor %}</table>
  {% else %}<p class="hint">No shares yet. Create one below.</p>{% endif %}
  <form method="post" action="/share">
   <label>New shared folder name</label>
   <input name="name" placeholder="e.g. family-photos" required pattern="[A-Za-z0-9_\\-]+">
   <button type="submit">Create share</button>
  </form>
  <p class="hint">Folders live under {{ storage }} and are shared over your home network (Samba).</p>
 </div>

 <div class="card"><h2>Reset</h2>
  <p class="hint">Start setup over — forget the current WiFi and go back to the
   first-time setup screen. Your files and admin account are kept.</p>
  <button type="button" id="resetBtn" class="danger-btn">Reset WiFi setup</button>
 </div>

</div>

<div class="modal-bg" id="resetModal">
 <div class="modal">
  <h3>Reset WiFi setup?</h3>
  <p>The gm-nas will:</p>
  <ul>
   <li>Forget its current WiFi network</li>
   <li>Reboot into setup mode (<b>GMNas-Setup</b>)</li>
   <li>Keep your files and admin account</li>
  </ul>
  <p>After it reboots, connect your phone to <b>GMNas-Setup</b> and open
   <b>http://192.168.42.1</b> to set it up again.</p>
  <div class="modal-actions">
   <button type="button" class="btn-cancel" id="resetCancel">Cancel</button>
   <form method="post" action="/reset"><button type="submit" class="danger-btn">Reset &amp; reboot</button></form>
  </div>
 </div>
</div>
<script>
 document.querySelectorAll('.eye').forEach(function(btn){
   btn.addEventListener('click', function(){
     var inp = btn.parentNode.querySelector('input');
     var show = inp.type === 'password';
     inp.type = show ? 'text' : 'password';
     btn.classList.toggle('on', show);
     btn.title = show ? 'Hide password' : 'Show password';
   });
 });
 // Install-progress refresh — reload every 5s to update app badges, but ONLY
 // while no text field is focused, so typing is never interrupted/wiped.
 {% if busy %}
 setInterval(function(){
   var a = document.activeElement, t = a ? a.tagName : '';
   var open = document.getElementById('resetModal');
   if (t !== 'INPUT' && t !== 'TEXTAREA' && !(open && open.classList.contains('open')))
     location.reload();
 }, 5000);
 {% endif %}
 // Reset modal (custom confirm dialog).
 (function(){
   var b=document.getElementById('resetBtn'), m=document.getElementById('resetModal'),
       c=document.getElementById('resetCancel');
   if(!b) return;
   b.addEventListener('click', function(){ m.classList.add('open'); });
   c.addEventListener('click', function(){ m.classList.remove('open'); });
   m.addEventListener('click', function(e){ if(e.target===m) m.classList.remove('open'); });
 })();
 // Live connectivity heartbeat — polls /status every 5s and updates the badge,
 // the same way the Tailscale row shows Connected/Not.
 (function(){
   var dot = document.getElementById('netdot');
   var txt = document.getElementById('nettext');
   var ipEl = document.getElementById('netip');
   function beat(){
     fetch('/status', {cache:'no-store'}).then(function(r){return r.json();}).then(function(s){
       dot.className = 'dot ' + (s.online ? 'ok' : 'off');
       txt.textContent = s.online ? 'Online' : 'Offline';
       ipEl.textContent = s.ip || '';
     }).catch(function(){
       dot.className = 'dot off'; txt.textContent = 'Offline';
     });
   }
   setInterval(beat, 5000);
 })();
</script>
</body></html>"""


def hostname():
    try:
        return subprocess.check_output(["hostname"], text=True).strip() + ".local"
    except Exception:
        return "my-gmnas.local"


def seed_version():
    try:
        with open("/etc/gmnas-seed-version") as f:
            return f.read().strip() or "?"
    except OSError:
        return "?"


def box_ip():
    try:
        out = subprocess.check_output(["hostname", "-I"], text=True).split()
        return out[0] if out else ""
    except Exception:
        return ""


def tailscale_ip():
    try:
        return subprocess.check_output(["tailscale", "ip", "-4"], text=True,
                                       stderr=subprocess.DEVNULL, timeout=5).strip()
    except Exception:
        return ""


# ---- background install helpers -------------------------------------------

def _paths(appname):
    return (os.path.join(RUN_DIR, appname + ".lock"),
            os.path.join(LOG_DIR, "install-" + appname + ".log"))


def is_installing(appname):
    lock, _ = _paths(appname)
    return os.path.exists(lock)


def start_install(appname, cmd):
    """Run `cmd` (a shell string) in the background, guarded by a lock file so
    it starts at most once. Safe to call repeatedly (e.g. Cockpit auto-start)."""
    os.makedirs(RUN_DIR, exist_ok=True)
    os.makedirs(LOG_DIR, exist_ok=True)
    lock, log = _paths(appname)
    if os.path.exists(lock):
        return  # already running
    # Create the lock atomically; if we lose the race, bail.
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        os.close(fd)
    except FileExistsError:
        return
    wrapped = "{ %s ; } >>'%s' 2>&1; rm -f '%s'" % (cmd, log, lock)
    subprocess.Popen(["/bin/bash", "-c", wrapped], start_new_session=True)


def cockpit_state():
    if shutil.which("cockpit-bridge") or os.path.isdir("/usr/share/cockpit"):
        return "ready"
    return "busy" if is_installing("setup") else "off"


def tailscale_state():
    if not shutil.which("tailscale"):
        return "busy" if is_installing("setup") else "off"
    # installed — are we logged in / up?
    try:
        out = subprocess.check_output(["tailscale", "status"], text=True,
                                      stderr=subprocess.STDOUT, timeout=6)
        if "Logged out" in out or "NeedsLogin" in out or "Stopped" in out:
            return "ready"
        return "up"
    except Exception:
        return "ready"


def tailscale_login_url():
    """Scrape the most recent login URL from the tailscale-up install log."""
    _, log = _paths("tailscale")
    try:
        with open(log) as f:
            text = f.read()
    except OSError:
        return None
    m = re.findall(r"https://login\.tailscale\.com/\S+", text)
    return m[-1] if m else None


def have_internet():
    return subprocess.run(["getent", "hosts", "github.com"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def list_shares():
    if not os.path.isdir(STORAGE):
        return []
    return sorted(d for d in os.listdir(STORAGE)
                  if os.path.isdir(os.path.join(STORAGE, d)))


def add_samba_share(name, path):
    block = (f"\n[{name}]\n   path = {path}\n   browseable = yes\n"
             f"   read only = no\n   guest ok = no\n   valid users = {ADMIN_USER}\n")
    conf = ""
    if os.path.exists(SMB_CONF):
        with open(SMB_CONF) as f:
            conf = f.read()
    if f"[{name}]" in conf:
        return
    if SMB_MARK not in conf:
        conf += "\n" + SMB_MARK + "\n"
    conf += block
    with open(SMB_CONF, "w") as f:
        f.write(conf)
    subprocess.run(["systemctl", "reload-or-restart", "smbd"], check=False)


# Shell one-liners for the background installers.
COCKPIT_CMD = ("export DEBIAN_FRONTEND=noninteractive; apt-get update; "
               "apt-get install -y cockpit; systemctl enable --now cockpit.socket")
TAILSCALE_CMD = ("curl -fsSL https://tailscale.com/install.sh | sh; "
                 "systemctl enable --now tailscaled")
TS_UP_CMD = ("tailscale up --accept-routes 2>&1 | tee -a '%s/install-tailscale.log'"
             % LOG_DIR)
# ttyd browser terminal (:7681) — a single static binary + its service unit.
# Not apt, so it can't collide on the dpkg lock; installed as part of the chain
# so the Terminal link actually works after setup.
TTYD_CMD = (
    "curl -fsSL https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64 "
    "-o /usr/local/bin/ttyd && chmod +x /usr/local/bin/ttyd && "
    "curl -fsSL https://raw.githubusercontent.com/affigabmag/gm-nas-pub/main/files/ttyd.service "
    "-o /etc/systemd/system/ttyd.service && systemctl daemon-reload && "
    "systemctl enable --now ttyd.service")
# ONE ordered chain (Cockpit -> terminal -> Tailscale -> sign-in link). Runs
# under a single 'setup' lock so two apt processes never collide on the dpkg
# lock. `tailscale up` blocks until the end user signs in, holding the lock.
SETUP_CMD = "; ".join([COCKPIT_CMD, TTYD_CMD, TAILSCALE_CMD, TS_UP_CMD])


@app.route("/")
def index():
    # First time this page is opened after setup (box is on stable home WiFi):
    #  - Cockpit auto-installs in the background.
    #  - Tailscale auto-installs, then auto-runs `tailscale up` to surface a
    #    one-time sign-in link. The END USER clicks it and logs into THEIR OWN
    #    Tailscale account — no auth key is baked into the box. Once they sign
    #    in, this box appears in their tailnet.
    pw_not_set = os.path.exists(PW_FLAG)
    cockpit = cockpit_state()
    tailscale = tailscale_state()
    # Kick off the ordered install chain (Cockpit -> ttyd -> Tailscale) only
    # AFTER the admin account exists. Starting it earlier turns on the 5s
    # progress-refresh, which would wipe the account form while it's being typed.
    done = cockpit == "ready" and tailscale == "up"
    if have_internet() and not pw_not_set and not done and not is_installing("setup"):
        start_install("setup", SETUP_CMD)

    busy = is_installing("setup")
    return render_template_string(
        PAGE, host=hostname(), admin=ADMIN_USER, storage=STORAGE,
        password_not_set=pw_not_set,
        shares=list_shares(),
        cockpit=cockpit, tailscale=tailscale,
        ts_login_url=(tailscale_login_url() if tailscale == "ready" else None),
        busy=busy, version=seed_version(),
        online=have_internet(), ip=box_ip(),
        msg=request.args.get("msg"), msgcls=request.args.get("cls", "ok"))


# Manual triggers (fallbacks) all funnel to the same ordered, serialized chain
# so nothing ever runs two apt processes at once.
@app.route("/install/cockpit", methods=["POST"])
@app.route("/install/tailscale", methods=["POST"])
def install_apps():
    if not have_internet():
        return redirect("/?cls=err&msg=No internet — connect to your home WiFi first.")
    start_install("setup", SETUP_CMD)
    return redirect("/?msg=Installing apps… Cockpit first, then Tailscale.")


@app.route("/tailscale/up", methods=["POST"])
def tailscale_up():
    if not shutil.which("tailscale"):
        return redirect("/?cls=err&msg=Install Tailscale first.")
    start_install("setup", TS_UP_CMD)
    return redirect("/?msg=Starting Tailscale… a sign-in link will appear below.")


# Forget saved WiFi (non-AP profiles), clear the provisioned flag, and reboot.
# On reboot, firstboot sees no active network and relaunches the setup AP.
RESET_CMD = (
    "sleep 1; rm -f /etc/homenas/provisioned; "
    "for c in $(nmcli -t -f NAME,TYPE connection show 2>/dev/null | "
    "awk -F: '$2 ~ /wireless/ && $1 !~ /GMNas-Setup|Hotspot|wifi-connect/ {print $1}'); "
    "do nmcli connection delete \"$c\"; done; "
    "sleep 2; systemctl reboot")

RESET_PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>gm-nas — resetting</title></head>
<body style="margin:0;background:#0f172a;color:#f1f5f9;font-family:-apple-system,Segoe UI,Roboto,sans-serif;
 text-align:center;padding:48px 20px">
 <div style="font-size:44px;margin-bottom:12px">↻</div>
 <h2 style="margin:0 0 10px">Resetting…</h2>
 <p style="color:#94a3b8;line-height:1.7">Your gm-nas is rebooting into setup mode.<br><br>
  On your phone, connect to <b style="color:#f1f5f9">GMNas-Setup</b><br>
  and open <b style="color:#f1f5f9">http://192.168.42.1</b><br>to set it up again.</p>
</body></html>"""


@app.route("/reset", methods=["POST"])
def reset():
    subprocess.Popen(["/bin/bash", "-c", RESET_CMD], start_new_session=True)
    return RESET_PAGE


@app.route("/status")
def status():
    ts = tailscale_state()
    return jsonify(online=have_internet(), ip=box_ip(),
                   tailscale=ts, tailscale_ip=(tailscale_ip() if ts == "up" else ""))


RESERVED_USERS = {"root", "gmnas", "gmadmin", "daemon", "bin", "sys", "sync",
                  "nobody", "admin", "ubuntu", "cockpit-ws", "sshd", "systemd"}


def user_exists(name):
    return subprocess.run(["id", name], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


@app.route("/account", methods=["POST"])
def create_account():
    user = request.form.get("username", "").strip()
    pw = request.form.get("pw", "")
    pw2 = request.form.get("pw2", "")
    # Linux username rules: start with a letter/underscore, then lowercase
    # letters/digits/-/_, max 32 chars total.
    if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", user):
        return redirect("/?cls=err&msg=Invalid username: lowercase, start with a letter, only letters/digits/-/_.")
    if user in RESERVED_USERS or user_exists(user):
        return redirect(f"/?cls=err&msg=Username '{escape(user)}' is taken — choose another.")
    if len(pw) < 8:
        return redirect("/?cls=err&msg=Password must be at least 8 characters.")
    if pw != pw2:
        return redirect("/?cls=err&msg=Passwords do not match.")
    # Create the admin account (sudo-capable, real shell, home dir).
    r = subprocess.run(["useradd", "-m", "-s", "/bin/bash", "-G", "sudo", user])
    if r.returncode != 0:
        return redirect("/?cls=err&msg=Could not create the account.")
    if subprocess.run(["chpasswd"], input=f"{user}:{pw}", text=True).returncode != 0:
        return redirect("/?cls=err&msg=Account created but setting the password failed.")
    try:
        os.remove(PW_FLAG)   # b1 flow done — Cockpit is now usable
    except FileNotFoundError:
        pass
    return redirect(f"/?msg=Admin account '{escape(user)}' created. Sign in to Cockpit with it.")


@app.route("/password", methods=["POST"])
def set_password():
    pw = request.form.get("pw", "")
    pw2 = request.form.get("pw2", "")
    if len(pw) < 8:
        return redirect("/?cls=err&msg=Password must be at least 8 characters.")
    if pw != pw2:
        return redirect("/?cls=err&msg=Passwords do not match.")
    r = subprocess.run(["chpasswd"], input=f"{ADMIN_USER}:{pw}", text=True)
    if r.returncode != 0:
        return redirect("/?cls=err&msg=Could not set password.")
    try:
        os.remove(PW_FLAG)
    except FileNotFoundError:
        pass
    return redirect("/?msg=Password set. You can now sign in to Cockpit.")


@app.route("/share", methods=["POST"])
def create_share():
    name = request.form.get("name", "").strip()
    if not re.fullmatch(r"[A-Za-z0-9_\-]+", name or ""):
        return redirect("/?cls=err&msg=Invalid folder name.")
    path = os.path.join(STORAGE, name)
    os.makedirs(path, exist_ok=True)
    subprocess.run(["chown", f"root:{ADMIN_USER}", path], check=False)
    subprocess.run(["chmod", "2775", path], check=False)
    add_samba_share(name, path)
    return redirect(f"/?msg=Share '{escape(name)}' created.")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
