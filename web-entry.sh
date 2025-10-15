#!/usr/bin/env bash
set -euo pipefail

# -------- Defaults (overridable by env) --------
: "${DJANGO_PROJECT:=webapp}"
: "${DJANGO_SECRET_KEY:=change-me}"
: "${DJANGO_DEBUG:=1}"
: "${DJANGO_ALLOWED_HOSTS:=kriss.karkark.net,localhost,127.0.0.1}"
: "${DJANGO_PORT:=8000}"

: "${DJANGO_DB_NAME:=appdb}"
: "${DJANGO_DB_USER:=appuser}"
: "${DJANGO_DB_PASSWORD:=apppass}"
: "${DJANGO_DB_HOST:=db20059}"
: "${DJANGO_DB_PORT:=5432}"

# -------- Python deps --------
python -m pip install --upgrade pip
pip install --no-cache-dir "Django>=5.0,<6.0" "psycopg2-binary>=2.9,<3.0"

# -------- Create project if missing --------
if [ ! -f manage.py ]; then
  django-admin startproject "$DJANGO_PROJECT" .
fi

# -------- Validate/repair settings.py if broken --------
repair_settings() {
  echo "⚠️  Invalid $DJANGO_PROJECT/settings.py — regenerating a clean one..."
  tmpdir="$(mktemp -d)"
  pushd "$tmpdir" >/dev/null
  django-admin startproject cleanproj .
  popd >/dev/null
  cp -f "$DJANGO_PROJECT/settings.py" "$DJANGO_PROJECT/settings.py.bak" 2>/dev/null || true
  cp -f "$tmpdir/cleanproj/settings.py" "$DJANGO_PROJECT/settings.py"
  rm -rf "$tmpdir"
}

python - <<PY || repair_settings
from pathlib import Path
p = Path("$DJANGO_PROJECT/settings.py")
compile(p.read_text(encoding="utf-8"), str(p), "exec")
print("✅ settings.py syntax OK")
PY

# -------- Patch settings safely (also fix cleanproj refs) --------
python - <<'PY'
import os, re
from pathlib import Path

proj = os.getenv("DJANGO_PROJECT","webapp")
p = Path(proj) / "settings.py"
s = p.read_text(encoding="utf-8")

# ensure import os
if not re.search(r'^\s*import\s+os\b', s, re.M):
    s = "import os\n" + s

# SECRET_KEY
if not re.search(r'^\s*SECRET_KEY\s*=', s, re.M):
    s = "SECRET_KEY = 'placeholder'\n" + s
s = re.sub(r"^\s*SECRET_KEY\s*=.*$", "SECRET_KEY = os.getenv('DJANGO_SECRET_KEY','change-me')", s, flags=re.M)

# DEBUG
if not re.search(r'^\s*DEBUG\s*=', s, re.M):
    s += '\nDEBUG = False\n'
s = re.sub(r'^\s*DEBUG\s*=.*$', "DEBUG = os.getenv('DJANGO_DEBUG','0') in ['1','true','True','yes','YES']", s, flags=re.M)

# ALLOWED_HOSTS
if not re.search(r'^\s*ALLOWED_HOSTS\s*=', s, re.M):
    s += '\nALLOWED_HOSTS = []\n'
s = re.sub(
    r'^\s*ALLOWED_HOSTS\s*=.*$',
    "ALLOWED_HOSTS = [h.strip() for h in os.getenv('DJANGO_ALLOWED_HOSTS','kriss.karkark.net,localhost,127.0.0.1').split(',') if h.strip()]",
    s, flags=re.M
)

# Ensure Django refers to the real project (not "cleanproj")
for name, val in [
    ("ROOT_URLCONF",      f"{proj}.urls"),
    ("WSGI_APPLICATION",  f"{proj}.wsgi.application"),
    ("ASGI_APPLICATION",  f"{proj}.asgi.application"),
]:
    pat = rf"^\s*{name}\s*=\s*['\"][^'\"]+['\"]\s*$"
    if re.search(pat, s, re.M):
        s = re.sub(pat, f"{name} = '{val}'", s, flags=re.M)
    else:
        s += f"\n{name} = '{val}'\n"

# CSRF_TRUSTED_ORIGINS
marker_csrf = "# --- container csrf origins ---"
if marker_csrf not in s:
    s += f"""
{marker_csrf}
_CS_ORIGINS = []
for _h in ALLOWED_HOSTS:
    if _h:
        _CS_ORIGINS += [f"http://{{_h}}:20059", f"https://{{_h}}:20059", f"http://{{_h}}", f"https://{{_h}}"]
CSRF_TRUSTED_ORIGINS = list(dict.fromkeys(_CS_ORIGINS))
"""

# DATABASES
if not re.search(r'^\s*DATABASES\s*=\s*{', s, re.M):
    s += '\nDATABASES = {"default": {}}\n'
marker_db = "# --- container db overrides ---"
db_override = f"""
{marker_db}
DATABASES.setdefault("default", {{}});
DATABASES["default"]["ENGINE"]   = "django.db.backends.postgresql"
DATABASES["default"]["NAME"]     = os.getenv("DJANGO_DB_NAME", "appdb")
DATABASES["default"]["USER"]     = os.getenv("DJANGO_DB_USER", "appuser")
DATABASES["default"]["PASSWORD"] = os.getenv("DJANGO_DB_PASSWORD", "apppass")
DATABASES["default"]["HOST"]     = os.getenv("DJANGO_DB_HOST", "db20059")
DATABASES["default"]["PORT"]     = os.getenv("DJANGO_DB_PORT", "5432")
"""
if marker_db not in s:
    s = s.rstrip() + "\n" + db_override + "\n"

# Static / TZ
if "STATIC_URL" not in s:
    s += '\nSTATIC_URL = "static/"\n'
if "STATIC_ROOT" not in s:
    s += '\nSTATIC_ROOT = os.path.join(os.path.dirname(__file__), "..", "staticfiles")\n'
if not re.search(r'^\s*TIME_ZONE\s*=', s, re.M):
    s += '\nTIME_ZONE = "Asia/Phnom_Penh"\n'
if not re.search(r'^\s*USE_TZ\s*=', s, re.M):
    s += '\nUSE_TZ = True\n'

p.write_text(s, encoding="utf-8")
compile(p.read_text(encoding="utf-8"), str(p), "exec")
print("✅ settings.py patched & valid (project refs fixed)")
PY

# -------- Wait for DB, migrate, run --------
echo "⏳ Waiting for Postgres at ${DJANGO_DB_HOST}:${DJANGO_DB_PORT} ..."
python - <<PY
import os, time, psycopg2
host = os.getenv("DJANGO_DB_HOST","db20059")
port = int(os.getenv("DJANGO_DB_PORT","5432"))
user = os.getenv("DJANGO_DB_USER","appuser")
pwd  = os.getenv("DJANGO_DB_PASSWORD","apppass")
db   = os.getenv("DJANGO_DB_NAME","appdb")
for i in range(60):
    try:
        conn = psycopg2.connect(host=host, port=port, user=user, password=pwd, dbname=db)
        conn.close()
        print("✅ Postgres is reachable")
        break
    except Exception as e:
        print(f"… waiting ({i+1}/60): {e}")
        time.sleep(1)
else:
    raise SystemExit("Postgres not reachable in time")
PY

python manage.py migrate --noinput
exec python manage.py runserver 0.0.0.0:"$DJANGO_PORT"

