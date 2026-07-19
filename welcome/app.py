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
import time
import json
import base64
import shutil
import subprocess
from html import escape
from flask import Flask, request, redirect, render_template_string, jsonify

app = Flask(__name__)

STORAGE = "/srv/storage"
PW_FLAG = "/etc/homenas/password-not-set"
ADMIN_USER = "gmnas"                       # fallback until the wizard creates one
ADMIN_USER_FILE = "/etc/homenas/admin-user"
SMB_CONF = "/etc/samba/smb.conf"
SMB_MARK = "# --- gm-nas managed shares ---"
WELCOME_VER = "01.04.20260719132811"   # bump on every welcome-app change
SHARES_JSON = "/etc/homenas/shares.json"
SHARES_SEEDED_FLAG = "/etc/homenas/shares-seeded"

# Created once at first setup. The whole storage partition ("/") is the main
# share; plus documents and a media/{pictures,video} tree.
DEFAULT_SHARES = [
    {"name": "storage",   "path": "/srv/storage",           "label": "/ (all storage)"},
    {"name": "documents", "path": "/srv/storage/documents", "label": "documents"},
    {"name": "media",     "path": "/srv/storage/media",     "label": "media"},
]

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
 .shares{margin-top:16px;display:grid;grid-template-columns:repeat(2,minmax(0,1fr));
  gap:8px;max-height:280px;overflow-y:auto;padding:2px}
 @media(max-width:430px){.shares{grid-template-columns:1fr}}
 .shrow{min-width:0;position:relative;display:flex;flex-direction:column;gap:1px;
  padding:8px 34px 8px 10px;border:1px solid var(--border);border-radius:9px;background:#0b1220}
 .shname{font-weight:600;font-size:14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
 .shpath{color:var(--muted);font-size:11px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
 .shdel{margin:0;position:absolute;top:8px;right:8px}
 .shdel button{margin:0;width:auto;padding:6px 11px;background:transparent;border:1px solid var(--border);
  color:var(--danger);border-radius:8px;font-size:13px;cursor:pointer;line-height:1}
 .shdel button:hover{background:rgba(248,113,113,.14);border-color:var(--danger)}
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
 header{position:sticky;top:0;z-index:20;background:var(--bg);margin:0 0 4px;
  padding:12px 0;border-bottom:1px solid var(--border)}
 .gear{position:absolute;top:0;right:0;margin:0;width:auto;padding:8px 11px;font-size:20px;
  line-height:1;background:var(--card);color:var(--muted);border:1px solid var(--border);border-radius:10px;cursor:pointer}
 .gear:hover{color:var(--fg)}
 .modal.manage{max-width:460px;text-align:left}
 .msec{padding:16px 0;border-top:1px solid var(--border)}
 .msec:first-of-type{border-top:none;padding-top:0}
 .msec h4{margin:0 0 4px;font-size:15px;color:var(--fg)}
</style></head><body><div class="wrap">
 <header><div class="logo"><svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="#04263a" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="7" rx="1.5"/><rect x="3" y="13" width="18" height="7" rx="1.5"/><circle cx="6.6" cy="7.5" r="0.9" fill="#04263a" stroke="none"/><circle cx="6.6" cy="16.5" r="0.9" fill="#04263a" stroke="none"/><line x1="9.5" y1="7.5" x2="17.5" y2="7.5"/><line x1="9.5" y1="16.5" x2="17.5" y2="16.5"/></svg></div><h1>Welcome to your gm-nas</h1>
  <p class="sub">{{ host }}</p>
  <div id="netstrip" class="netstrip">
    <span id="netdot" class="dot {{ 'ok' if online else 'off' }}"></span>
    <span id="nettext">{{ 'Online' if online else 'Offline' }}</span>
    <span id="netip" class="ip">{{ ip }}</span>
    <span class="ip sep">· version <b>{{ build }}</b></span>
  </div>
  {% if not password_not_set %}<button type="button" id="gearBtn" class="gear" title="Manage NAS" aria-label="Manage NAS">⚙</button>{% endif %}
 </header>

 {% if msg %}<div class="card"><div class="msg {{ msgcls }}">{{ msg }}</div></div>{% endif %}

 {% if password_not_set %}
 <div class="card"><h2>1. Create your admin account</h2>
  <p class="hint">Your sign-in for Cockpit and admin tasks. Pick any username you like.</p>
  <form method="post" action="/account">
   <label>Device name</label>
   <input name="hostname" value="{{ hostbase }}" required autocapitalize="none" autocomplete="off"
          pattern="[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?">
   <div class="hint">How this unit appears on your network: <b>&lt;name&gt;.local</b>.
    Suggested from your WiFi — edit it, or use a unique name if you have more than one gm-nas.</div>
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
   {% if cockpit == 'ready' %}<a class="linkbtn svclink" data-proto="https" data-port="9090" href="https://{{ host }}:9090" target="_blank">Open ↗</a>
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
   <a class="svclink" data-proto="https" data-port="9090" href="https://{{ host }}:9090" target="_blank">Cockpit admin ↗</a>
   <a class="svclink" data-proto="http" data-port="7681" href="http://{{ host }}:7681" target="_blank">Terminal ↗</a>
  </div>
  <p class="hint">Cockpit: system, storage, logs, updates. Terminal: a shell in your browser.</p>
 </div>

 <div class="card"><h2>File shares</h2>
  {% if not samba %}<p class="hint">Setting up file sharing… shares appear once Samba finishes installing.</p>{% endif %}
  <form method="post" action="/share">
   <label>Folder</label>
   <select id="folderSel" name="folder">
     <option value="">/ (storage root)</option>
     {% for f in folders %}<option value="{{ f }}">{{ f }}</option>{% endfor %}
   </select>
   <label>New subfolder name <span style="opacity:.6">(optional)</span></label>
   <input id="newFolder" name="newname" pattern="[a-z0-9_\\-]+" autocapitalize="none"
          placeholder="leave empty to share the folder above">
   <button type="submit">Create share</button>
  </form>
  <p class="hint">Pick a folder to share it. To make a new folder, pick its parent above and
   type a name — it's created inside that parent (e.g. <b>media</b> + <b>family</b> → <b>media/family</b>).
   Everything lives under {{ storage }}, shared over your home network (Samba).</p>
  <div class="shares">
  {% for s in shares %}
    <div class="shrow">
      <span class="shname">📁 {{ s.label or s.name }}</span>
      <code class="shpath">\\\\{{ host }}\\{{ s.name }}</code>
      <form method="post" action="/share/delete" class="shdel">
        <input type="hidden" name="name" value="{{ s.name }}">
        <button type="submit" title="Remove this share (files are kept)" aria-label="Remove">✕</button>
      </form>
    </div>
  {% else %}
    <p class="hint">No shares yet.</p>
  {% endfor %}
  </div>
 </div>


</div>

<div class="modal-bg" id="manageModal">
 <div class="modal manage">
  <h3>Manage NAS</h3>

  <div class="msec">
   <h4>Device name</h4>
   <p class="hint">Appears on your network as <b>&lt;name&gt;.local</b>.</p>
   <form method="post" action="/rename">
    <input name="hostname" value="{{ hostbase }}" required autocapitalize="none" autocomplete="off"
           pattern="[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?">
    <button type="submit">Rename &amp; apply</button>
   </form>
  </div>

  <div class="msec">
   <h4>Admin password</h4>
   <p class="hint">Sign-in for Cockpit and admin tasks (user <b>{{ admin }}</b>).</p>
   <form method="post" action="/password">
    <label>New password</label>
    <div class="pass-wrap"><input type="password" name="pw" class="pw" required minlength="8">
     <button type="button" class="eye" aria-label="Show password">👁</button></div>
    <label>Confirm password</label>
    <div class="pass-wrap"><input type="password" name="pw2" class="pw" required minlength="8">
     <button type="button" class="eye" aria-label="Show password">👁</button></div>
    <button type="submit">Update password</button>
   </form>
  </div>

  <div class="msec">
   <h4>Reset</h4>
   <p class="hint">Forget WiFi and return to first-time setup. Files &amp; account kept.</p>
   <button type="button" id="resetOpen" class="danger-btn">Reset WiFi setup</button>
  </div>

  <div class="modal-actions">
   <button type="button" class="btn-cancel" id="manageClose">Close</button>
  </div>
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
   var rOpen = document.getElementById('resetModal');
   var mOpen = document.getElementById('manageModal');
   function isOpen(el){ return el && el.classList.contains('open'); }
   if (t !== 'INPUT' && t !== 'TEXTAREA' && !isOpen(rOpen) && !isOpen(mOpen))
     location.reload();
 }, 5000);
 {% endif %}
 // Point Cockpit/Terminal links at the SAME host you're using now (IP, .local,
 // or Tailscale) — the baked-in .local name doesn't resolve on Windows/Android.
 (function(){
   var h = location.hostname;
   document.querySelectorAll('.svclink').forEach(function(a){
     a.href = a.dataset.proto + '://' + h + ':' + a.dataset.port;
   });
 })();
 // Manage NAS panel (gear) + Reset confirm dialog.
 (function(){
   var g=document.getElementById('gearBtn'),
       mm=document.getElementById('manageModal'), mc=document.getElementById('manageClose'),
       rm=document.getElementById('resetModal'), rc=document.getElementById('resetCancel'),
       ro=document.getElementById('resetOpen');
   function close(el){ if(el) el.classList.remove('open'); }
   if(g&&mm){ g.addEventListener('click', function(){ mm.classList.add('open'); }); }
   if(mc){ mc.addEventListener('click', function(){ close(mm); }); }
   if(mm){ mm.addEventListener('click', function(e){ if(e.target===mm) close(mm); }); }
   if(ro&&rm){ ro.addEventListener('click', function(){ close(mm); rm.classList.add('open'); }); }
   if(rc){ rc.addEventListener('click', function(){ close(rm); }); }
   if(rm){ rm.addEventListener('click', function(e){ if(e.target===rm) close(rm); }); }
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


def hostbase():
    try:
        return subprocess.check_output(["hostname"], text=True).strip()
    except Exception:
        return "my-gmnas"


def hostname():
    return hostbase() + ".local"


def admin_username():
    """The account the wizard created (Cockpit login); ADMIN_USER until then."""
    try:
        with open(ADMIN_USER_FILE) as f:
            u = f.read().strip()
            if u:
                return u
    except OSError:
        pass
    return ADMIN_USER


def set_smb_password(user, pw):
    """Register/update the account in Samba's password DB with the same password
    so the end user can open the shares from Windows with their own login
    (no insecure-guest needed). No-op if Samba isn't installed yet.

    Retries once: right after boot/install, smbd's passdb backend can briefly
    not be ready yet, and smbpasswd fails silently otherwise (subprocess.run
    doesn't raise on a non-zero exit -- a prior version of this function never
    checked the return code, so a failed registration looked identical to a
    successful one).
    """
    if not samba_installed():
        return
    smbpasswd = shutil.which("smbpasswd") or "/usr/bin/smbpasswd"
    r = None
    for attempt in range(2):
        try:
            # -s: read pw from stdin (twice); -a: add if new.
            r = subprocess.run([smbpasswd, "-s", "-a", user], input=f"{pw}\n{pw}\n",
                               text=True, capture_output=True)
        except Exception as e:
            r = None
            _log_smb_failure(user, f"exception: {e}")
        if r is not None and r.returncode == 0:
            subprocess.run([smbpasswd, "-e", user], capture_output=True)
            return
        if attempt == 0:
            time.sleep(2)
    if r is not None:
        _log_smb_failure(user, f"rc={r.returncode} stderr={r.stderr!r}")


def _log_smb_failure(user, detail):
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(os.path.join(LOG_DIR, "smbpasswd.log"), "a") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {user}: {detail}\n")
    except OSError:
        pass


def active_ssid():
    """Currently connected WiFi SSID (empty if none / wired / AP mode)."""
    try:
        out = subprocess.check_output(
            ["nmcli", "-t", "-f", "ACTIVE,SSID", "dev", "wifi"],
            text=True, stderr=subprocess.DEVNULL, timeout=5)
        for line in out.splitlines():
            if line.startswith("yes:"):
                return line.split(":", 1)[1].strip()
    except Exception:
        pass
    return ""


def suggested_hostname():
    """Prefill for the Device name box: my-gmnas-<wifiname> when on WiFi.

    Leaves an already-customized hostname untouched so re-opening the page
    doesn't keep appending the SSID.
    """
    base = hostbase()
    if base != "my-gmnas":
        return base
    ssid = active_ssid()
    if not ssid:
        return base
    # sanitize to a valid DNS/hostname label
    tag = re.sub(r"[^a-z0-9-]", "-", ssid.lower()).strip("-")
    tag = re.sub(r"-+", "-", tag)
    return f"{base}-{tag}" if tag else base


def set_hostname(name):
    """Set the system hostname so the unit is reachable at <name>.local (mDNS)."""
    subprocess.run(["hostnamectl", "set-hostname", name], check=False)
    try:
        with open("/etc/hosts") as f:
            lines = f.readlines()
        out, found = [], False
        for ln in lines:
            if ln.startswith("127.0.1.1"):
                out.append(f"127.0.1.1\t{name}\n"); found = True
            else:
                out.append(ln)
        if not found:
            out.append(f"127.0.1.1\t{name}\n")
        with open("/etc/hosts", "w") as f:
            f.writelines(out)
    except OSError:
        pass
    subprocess.run(["systemctl", "restart", "avahi-daemon"], check=False)


def seed_version():
    try:
        with open("/etc/gmnas-seed-version") as f:
            return f.read().strip() or "?"
    except OSError:
        return "?"


def build_version():
    """One overall build id (from the repo VERSION file); bumps on any change."""
    try:
        with open("/etc/gmnas-build-version") as f:
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
    # Installed — is THIS node still a live member of the tailnet?
    #
    # We can't trust BackendState alone: a node that was DELETED from the
    # tailnet (or whose key expired) keeps BackendState "Running" while it can
    # no longer reach the coordination server. The authoritative signal is
    # Self.Online — it goes false the moment the node is deleted/logged out.
    try:
        out = subprocess.check_output(["tailscale", "status", "--json"], text=True,
                                      stderr=subprocess.STDOUT, timeout=6)
        d = json.loads(out)
        if d.get("BackendState") in ("NeedsLogin", "Stopped", "NoState", "Starting"):
            return "ready"
        self_node = d.get("Self") or {}
        if not self_node.get("Online", False):
            return "ready"          # deleted / expired / offline from control
        for h in (d.get("Health") or []):
            if "logged out" in str(h).lower():
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


def samba_installed():
    return shutil.which("smbd") is not None or os.path.exists("/usr/sbin/smbd")


def load_shares():
    try:
        with open(SHARES_JSON) as f:
            return json.load(f)
    except (OSError, ValueError):
        return []


def _write_smb(shares):
    """Regenerate the gm-nas managed block of smb.conf from the share list."""
    conf = ""
    if os.path.exists(SMB_CONF):
        with open(SMB_CONF) as f:
            conf = f.read()
    # Drop our previous managed block before rewriting it.
    if SMB_MARK in conf:
        conf = conf.split(SMB_MARK, 1)[0].rstrip() + "\n"
    # Guarantee a [global] that maps unknown users to guest — WITHOUT it the
    # "guest ok" shares are unreachable (Samba defaults to map to guest = Never),
    # so anonymous access from the home LAN is refused. Some minimal Samba
    # installs ship no [global] at all, so add the whole section if missing.
    if re.search(r"(?mi)^\s*\[global\]", conf):
        if "map to guest" not in conf:
            conf = re.sub(r"(?mi)^(\s*\[global\][^\n]*\n)",
                          r"\1   map to guest = Bad User\n", conf, count=1)
    else:
        conf = "[global]\n   map to guest = Bad User\n\n" + conf
    block = SMB_MARK + "\n"
    for s in shares:
        block += (f"\n[{s['name']}]\n   path = {s['path']}\n   browseable = yes\n"
                  f"   read only = no\n   guest ok = yes\n   force user = {ADMIN_USER}\n"
                  f"   create mask = 0664\n   directory mask = 2775\n")
    with open(SMB_CONF, "w") as f:
        f.write(conf.rstrip() + "\n\n" + block)
    if samba_installed():
        subprocess.run(["systemctl", "reload-or-restart", "smbd"], check=False)


def save_shares(shares):
    os.makedirs(os.path.dirname(SHARES_JSON), exist_ok=True)
    with open(SHARES_JSON, "w") as f:
        json.dump(shares, f)
    _write_smb(shares)


def _prep_folder(path):
    os.makedirs(path, exist_ok=True)
    subprocess.run(["chown", f"root:{ADMIN_USER}", path], check=False)
    subprocess.run(["chmod", "2775", path], check=False)


def ensure_default_shares():
    """One-time: create the default folder tree + shares (whole storage + tree).

    Seeds once, tracked by SHARES_SEEDED_FLAG (not by shares.json existing) so an
    empty/partial shares.json written before Samba finished doesn't block seeding.
    Merges with any shares already present and never resurrects after the one-time
    seed, so intentional deletes stick.
    """
    if os.path.exists(SHARES_SEEDED_FLAG):
        return
    existing = load_shares()
    have = {s["path"] for s in existing}
    for s in DEFAULT_SHARES:
        _prep_folder(s["path"])
    # Handy starter subfolders inside the media share (not separate shares).
    for sub in ("media/pictures", "media/video"):
        _prep_folder(os.path.join(STORAGE, sub))
    merged = existing + [dict(s) for s in DEFAULT_SHARES if s["path"] not in have]
    save_shares(merged)
    try:
        os.makedirs(os.path.dirname(SHARES_SEEDED_FLAG), exist_ok=True)
        open(SHARES_SEEDED_FLAG, "w").close()
    except OSError:
        pass


def ensure_smb_guest():
    """Heal older boxes whose smb.conf was written without guest mapping, so
    existing shares become anonymously reachable without recreating them."""
    try:
        with open(SMB_CONF) as f:
            conf = f.read()
    except OSError:
        return
    if "map to guest" not in conf:
        _write_smb(load_shares())


def available_folders():
    """Every directory under /srv/storage, up to 3 levels deep.

    Includes already-shared folders: they're valid *parents* to create a new
    subfolder inside (e.g. pick 'media' and add 'family'). The share handler
    rejects re-sharing one that's already shared.
    """
    out = []
    if not os.path.isdir(STORAGE):
        return out

    def walk(abspath, rel, depth):
        try:
            entries = sorted(os.listdir(abspath))
        except OSError:
            return
        for name in entries:
            if name.startswith(".") or name == "lost+found":
                continue
            ap = os.path.join(abspath, name)
            if not os.path.isdir(ap):
                continue
            rp = f"{rel}/{name}" if rel else name
            out.append(rp)
            if depth < 3:
                walk(ap, rp, depth + 1)

    walk(STORAGE, "", 1)
    return out


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
# Samba for file sharing (the File-shares card + default shares need it).
SAMBA_CMD = ("export DEBIAN_FRONTEND=noninteractive; apt-get install -y samba; "
             "systemctl enable --now smbd nmbd")
# ONE ordered chain (Cockpit -> terminal -> Tailscale -> sign-in link). Runs
# under a single 'setup' lock so two apt processes never collide on the dpkg
# lock. `tailscale up` blocks until the end user signs in, holding the lock.
SETUP_CMD = "; ".join([COCKPIT_CMD, TTYD_CMD, SAMBA_CMD, TAILSCALE_CMD, TS_UP_CMD])


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
    # Once Samba is installed, seed the default shares (whole storage + tree).
    if samba_installed():
        ensure_default_shares()
        ensure_smb_guest()
    return render_template_string(
        PAGE, host=hostname(), admin=admin_username(), storage=STORAGE,
        password_not_set=pw_not_set,
        shares=load_shares(), samba=samba_installed(), folders=available_folders(),
        hostbase=suggested_hostname(),
        cockpit=cockpit, tailscale=tailscale,
        ts_login_url=(tailscale_login_url() if tailscale == "ready" else None),
        busy=busy, version=seed_version(), appver=WELCOME_VER, build=build_version(),
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


# Discovery marker ("implanted id"): the setup portal image-probes candidate
# LAN IPs for this exact 1x1 PNG to find the box after it reboots onto WiFi.
_MARKER_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")


@app.route("/gmnas-id.png")
def gmnas_id():
    return app.response_class(_MARKER_PNG, mimetype="image/png",
                              headers={"Access-Control-Allow-Origin": "*",
                                       "Cache-Control": "no-store"})


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
    dev = request.form.get("hostname", "").strip().lower()
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
    if dev and not re.fullmatch(r"[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?", dev):
        return redirect("/?cls=err&msg=Invalid device name: lowercase letters, digits and hyphens.")
    # Create the admin account (sudo-capable, real shell, home dir).
    r = subprocess.run(["useradd", "-m", "-s", "/bin/bash", "-G", "sudo", user])
    if r.returncode != 0:
        return redirect("/?cls=err&msg=Could not create the account.")
    if subprocess.run(["chpasswd"], input=f"{user}:{pw}", text=True).returncode != 0:
        return redirect("/?cls=err&msg=Account created but setting the password failed.")
    # Remember who the admin is, so "change password" later targets this account.
    try:
        os.makedirs(os.path.dirname(ADMIN_USER_FILE), exist_ok=True)
        with open(ADMIN_USER_FILE, "w") as f:
            f.write(user + "\n")
    except OSError:
        pass
    # Give this account a matching Samba login so it can open the shares.
    set_smb_password(user, pw)
    # Name the unit (so it's reachable at <name>.local — distinguishes units).
    renamed = bool(dev and dev != hostbase())
    if renamed:
        set_hostname(dev)
    try:
        os.remove(PW_FLAG)   # b1 flow done — Cockpit is now usable
    except FileNotFoundError:
        pass
    msg = f"Admin account '{escape(user)}' created. Sign in to Cockpit with it."
    if renamed:
        # avahi just restarted — redirect via the IP so the reload always works,
        # and tell the user the new .local name to bookmark.
        ip = box_ip()
        target = f"http://{ip}" if ip else "/"
        return redirect(f"{target}/?msg=Admin '{escape(user)}' created. Your gm-nas is now '{escape(dev)}.local'.")
    return redirect(f"/?msg={msg}")


@app.route("/rename", methods=["POST"])
def rename_device():
    dev = request.form.get("hostname", "").strip().lower()
    if not re.fullmatch(r"[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?", dev):
        return redirect("/?cls=err&msg=Invalid device name: lowercase letters, digits and hyphens.")
    if dev == hostbase():
        return redirect("/?msg=Device name unchanged.")
    set_hostname(dev)
    ip = box_ip()   # avahi just restarted — redirect via IP so the reload always works
    target = f"http://{ip}" if ip else "/"
    return redirect(f"{target}/?msg=Your gm-nas is now '{escape(dev)}.local'.")


@app.route("/password", methods=["POST"])
def set_password():
    pw = request.form.get("pw", "")
    pw2 = request.form.get("pw2", "")
    if len(pw) < 8:
        return redirect("/?cls=err&msg=Password must be at least 8 characters.")
    if pw != pw2:
        return redirect("/?cls=err&msg=Passwords do not match.")
    admin = admin_username()
    r = subprocess.run(["chpasswd"], input=f"{admin}:{pw}", text=True)
    if r.returncode != 0:
        return redirect("/?cls=err&msg=Could not set password.")
    set_smb_password(admin, pw)   # keep the Samba login in sync
    try:
        os.remove(PW_FLAG)
    except FileNotFoundError:
        pass
    return redirect(f"/?msg=Password updated for '{escape(admin)}'.")


@app.route("/share", methods=["POST"])
def create_share():
    folder = request.form.get("folder", "").strip().strip("/")   # selected parent ("" = root)
    newname = request.form.get("newname", "").strip().lower()
    # Validate the parent (may be empty = storage root); no "..", no leading /.
    if folder and (not re.fullmatch(r"[a-z0-9_\-/]+", folder) or ".." in folder):
        return redirect("/?cls=err&msg=Invalid folder.")
    if newname:
        # Create a new subfolder inside the selected parent.
        if not re.fullmatch(r"[a-z0-9_\-]+", newname):
            return redirect("/?cls=err&msg=Invalid subfolder name: lowercase, digits, - and _.")
        rel = f"{folder}/{newname}" if folder else newname
    else:
        # Share the selected folder itself.
        if not folder:
            return redirect("/?cls=err&msg=Pick a folder, or type a new subfolder name.")
        rel = folder
    name = rel.replace("/", "-").lower()
    path = os.path.join(STORAGE, rel)
    # (a) never create a share that already exists — by name OR by folder path.
    shares = load_shares()
    if any(s["name"] == name or s.get("path") == path for s in shares):
        return redirect(f"/?cls=err&msg='{escape(rel)}' is already shared.")
    _prep_folder(path)   # (c) creates the folder (and any parents) if new
    shares.append({"name": name, "path": path, "label": rel})
    save_shares(shares)
    return redirect(f"/?msg=Share '{escape(name)}' created.")


@app.route("/share/delete", methods=["POST"])
def delete_share():
    name = request.form.get("name", "").strip()
    shares = [s for s in load_shares() if s["name"] != name]
    save_shares(shares)   # removes the Samba share; the folder + files are kept
    return redirect(f"/?msg=Share '{escape(name)}' removed (files kept).")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
