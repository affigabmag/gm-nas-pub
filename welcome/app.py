#!/usr/bin/env python3
# ============================================================================
# gm-nas welcome app  (Step 4)
# ----------------------------------------------------------------------------
# Lightweight post-setup web UI, served on http://my-gmnas.local (port 80).
# Runs as root via gmnas-welcome.service so it can set the admin password and
# manage Samba shares.
#
#   - Set the admin password (b1 flow): chpasswd for `gmnas`, then remove the
#     /etc/homenas/password-not-set flag (unlocks Cockpit login).
#   - Quick links: Cockpit (:9090) and the browser terminal (ttyd :7681).
#   - Shares: list folders under /srv/storage, create a folder + Samba share.
#
# No secrets in this file — safe in the public repo.
# ============================================================================
import os
import re
import subprocess
from html import escape
from flask import Flask, request, redirect, render_template_string

app = Flask(__name__)

STORAGE = "/srv/storage"
PW_FLAG = "/etc/homenas/password-not-set"
ADMIN_USER = "gmnas"
SMB_CONF = "/etc/samba/smb.conf"
SMB_MARK = "# --- gm-nas managed shares ---"

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>gm-nas</title>
<style>
 :root{--bg:#0f172a;--card:#1e293b;--fg:#f1f5f9;--muted:#94a3b8;--accent:#38bdf8;
  --accent-fg:#04263a;--border:#334155;--ok:#4ade80;--danger:#f87171}
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


@app.route("/")
def index():
    return render_template_string(
        PAGE, host=hostname(), admin=ADMIN_USER, storage=STORAGE,
        password_not_set=os.path.exists(PW_FLAG),
        shares=list_shares(),
        msg=request.args.get("msg"), msgcls=request.args.get("cls", "ok"))


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
