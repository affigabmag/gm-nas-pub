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
from flask import Flask, request, redirect, render_template_string

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
{% if busy %}<meta http-equiv="refresh" content="5">{% endif %}
<title>gm-nas</title>
<style>
 :root{--bg:#0f172a;--card:#1e293b;--fg:#f1f5f9;--muted:#94a3b8;--accent:#38bdf8;
  --accent-fg:#04263a;--border:#334155;--ok:#4ade80;--danger:#f87171;--warn:#fbbf24}
 *{box-sizing:border-box} body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
  background:var(--bg);color:var(--fg);padding:16px}
 .wrap{max-width:720px;margin:0 auto}
 header{text-align:center;margin:24px 0}
 .logo{width:56px;height:56px;margin:0 auto 12px;border-radius:14px;
  background:linear-gradient(135deg,var(--accent),#6366f1);display:flex;align-items:center;
  justify-content:center;font-size:26px;font-weight:700;color:var(--accent-fg)}
 h1{font-size:22px;margin:0} .sub{color:var(--muted);margin:4px 0 0}
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
 <header><div class="logo">N</div><h1>Welcome to your gm-nas</h1>
  <p class="sub">{{ host }}</p></header>

 {% if msg %}<div class="card"><div class="msg {{ msgcls }}">{{ msg }}</div></div>{% endif %}

 {% if password_not_set %}
 <div class="card"><h2>1. Set your admin password</h2>
  <p class="hint">Needed to sign in to Cockpit and to run admin tasks. User: <b>{{ admin }}</b>.</p>
  <form method="post" action="/password">
   <label>New password</label><input type="password" name="pw" required minlength="8">
   <label>Confirm password</label><input type="password" name="pw2" required minlength="8">
   <button type="submit">Set password</button>
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
</div></body></html>"""


def hostname():
    try:
        return subprocess.check_output(["hostname"], text=True).strip() + ".local"
    except Exception:
        return "my-gmnas.local"


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
    return "busy" if is_installing("cockpit") else "off"


def tailscale_state():
    if not shutil.which("tailscale"):
        return "busy" if is_installing("tailscale") else "off"
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


@app.route("/")
def index():
    # First time this page is opened after setup (box is on stable home WiFi):
    #  - Cockpit auto-installs in the background.
    #  - Tailscale auto-installs, then auto-runs `tailscale up` to surface a
    #    one-time sign-in link. The END USER clicks it and logs into THEIR OWN
    #    Tailscale account — no auth key is baked into the box. Once they sign
    #    in, this box appears in their tailnet.
    if have_internet():
        if cockpit_state() == "off":
            start_install("cockpit", COCKPIT_CMD)
        ts = tailscale_state()
        if ts == "off":
            start_install("tailscale", TAILSCALE_CMD)
        elif ts == "ready" and not tailscale_login_url():
            start_install("tailscale", "tailscale up --accept-routes")

    cockpit = cockpit_state()
    tailscale = tailscale_state()
    busy = (cockpit == "busy" or tailscale == "busy"
            or is_installing("cockpit") or is_installing("tailscale"))
    return render_template_string(
        PAGE, host=hostname(), admin=ADMIN_USER, storage=STORAGE,
        password_not_set=os.path.exists(PW_FLAG),
        shares=list_shares(),
        cockpit=cockpit, tailscale=tailscale,
        ts_login_url=(tailscale_login_url() if tailscale == "ready" else None),
        busy=busy,
        msg=request.args.get("msg"), msgcls=request.args.get("cls", "ok"))


@app.route("/install/cockpit", methods=["POST"])
def install_cockpit():
    if not have_internet():
        return redirect("/?cls=err&msg=No internet — connect to your home WiFi first.")
    start_install("cockpit", COCKPIT_CMD)
    return redirect("/?msg=Installing Cockpit…")


@app.route("/install/tailscale", methods=["POST"])
def install_tailscale():
    if not have_internet():
        return redirect("/?cls=err&msg=No internet — connect to your home WiFi first.")
    start_install("tailscale", TAILSCALE_CMD)
    return redirect("/?msg=Installing Tailscale…")


@app.route("/tailscale/up", methods=["POST"])
def tailscale_up():
    if not shutil.which("tailscale"):
        return redirect("/?cls=err&msg=Install Tailscale first.")
    # `tailscale up` prints a login URL; capture it into the install log so the
    # page can surface it. Background it (the command blocks until auth).
    _, log = _paths("tailscale")
    start_install("tailscale", "tailscale up --accept-routes 2>&1 | tee -a '%s'" % log)
    return redirect("/?msg=Starting Tailscale… a sign-in link will appear below.")


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
