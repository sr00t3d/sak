#!/usr/bin/env bash
# ==============================================================================
# sak.sh — Swiss Army Knife: CMS & cPanel Operations Toolkit CLI (v2.0.0)
# Modernized clean-room implementation inspired by legacy sak (2013, Jon South).
# Copyright (c) 2026 Percio Castelo — Apache-2.0 License
# ==============================================================================
set -euo pipefail

VERSION="2.0.0"

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required (3.6+)." >&2
    exit 1
fi

read -r -d '' PY_SCRIPT << 'EOF' || true
import argparse
import csv
import datetime
import hashlib
import io
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

VERSION = "2.0.0"

CMS_SIGNATURES = [
    ("WordPress", ["wp-includes/version.php", "wp-config.php"], "wp-includes/version.php", r"\$wp_version\s*=\s*['\"]([^'\"]+)['\"]"),
    ("Joomla", ["administrator/manifests/files/joomla.xml", "configuration.php"], "administrator/manifests/files/joomla.xml", r"<version>([^<]+)</version>"),
    ("Drupal", ["core/lib/Drupal.php", "sites/default/settings.php"], "core/lib/Drupal.php", r"const\s+VERSION\s*=\s*['\"]([^'\"]+)['\"]"),
    ("Laravel", ["artisan", "composer.json"], "composer.json", r"\"laravel/framework\"\s*:\s*\"[^\d]*([0-9]+(?:\.[0-9]+){0,2})"),
    ("Next.js", ["package.json"], "package.json", r"\"next\"\s*:\s*\"[^\d]*([0-9]+(?:\.[0-9]+){1,2})"),
]

DEFINE_RX = re.compile(
    r"""define\s*\(\s*['"](DB_NAME|DB_USER|DB_PASSWORD|DB_HOST)['"]\s*,\s*(['"])(.*?)\2\s*\)""",
    re.DOTALL,
)
PREFIX_RX = re.compile(r"""^\s*\$table_prefix\s*=\s*(['"])([^'"]+)\1""", re.MULTILINE)


class Colors:
    def __init__(self, enabled=True):
        self.RESET = "\033[0m" if enabled else ""
        self.BOLD = "\033[1m" if enabled else ""
        self.CYAN = "\033[36m" if enabled else ""
        self.GREEN = "\033[32m" if enabled else ""
        self.YELLOW = "\033[33m" if enabled else ""
        self.RED = "\033[31m" if enabled else ""
        self.DIM = "\033[2m" if enabled else ""


def resolve_target_paths(path_arg, user_arg, reseller_arg, etc_root="/etc"):
    paths = []
    if path_arg:
        paths.extend(p.strip() for p in path_arg.split(",") if p.strip())
    users = []
    if user_arg:
        users.extend(u.strip() for u in user_arg.split(",") if u.strip())
    if reseller_arg:
        tuo = os.path.join(etc_root, "trueuserowners")
        if os.path.isfile(tuo):
            with open(tuo, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if ":" in line:
                        u, owner = line.split(":", 1)
                        if owner.strip() == reseller_arg:
                            users.append(u.strip())
    for u in users:
        try:
            pw = pwd.getpwnam(u)
            pub = os.path.join(pw.pw_dir, "public_html")
            paths.append(pub if os.path.isdir(pub) else pw.pw_dir)
        except KeyError:
            sys.stderr.write(f"Warning: user '{u}' not found.\n")
    if not paths:
        paths = [os.getcwd()]
    return [os.path.abspath(p) for p in paths]


def cmd_scan(args):
    paths = resolve_target_paths(args.path, args.user, args.reseller, args.etc_root)
    findings = []
    seen = set()
    for base in paths:
        if not os.path.isdir(base):
            continue
        base_depth = base.rstrip(os.sep).count(os.sep)
        for root, dirs, _files in os.walk(base, followlinks=False):
            dirs[:] = [d for d in dirs if d not in ("node_modules", ".git", "virtfs", "cache", "tmp")]
            cur_depth = root.rstrip(os.sep).count(os.sep) - base_depth
            if args.maxdepth >= 0 and cur_depth > args.maxdepth:
                dirs[:] = []
                continue
            for name, markers, vfile, vrx in CMS_SIGNATURES:
                if any(os.path.exists(os.path.join(root, m)) for m in markers):
                    if name == "Next.js":
                        pj = os.path.join(root, "package.json")
                        try:
                            with open(pj, "r", encoding="utf-8", errors="replace") as fh:
                                if '"next"' not in fh.read():
                                    continue
                        except OSError:
                            continue
                    ver = "UNKNOWN"
                    vp = os.path.join(root, vfile)
                    if os.path.isfile(vp):
                        try:
                            with open(vp, "r", encoding="utf-8", errors="replace") as fh:
                                m = re.search(vrx, fh.read(65536))
                            if m:
                                ver = m.group(1)
                        except OSError:
                            pass
                    key = (name, root)
                    if key not in seen:
                        seen.add(key)
                        findings.append({"application": name, "version": ver, "path": root})
    return findings


def cmd_wp_info(args):
    paths = resolve_target_paths(args.path, args.user, None, args.etc_root)
    results = []
    mysql_bin = shutil.which("mysql") or shutil.which("mariadb")

    for base in paths:
        for root, dirs, files in os.walk(base, followlinks=False):
            dirs[:] = [d for d in dirs if d not in ("node_modules", ".git", "virtfs", "cache")]
            if "wp-config.php" not in files:
                continue
            cfg_path = os.path.join(root, "wp-config.php")
            info = {
                "path": root,
                "wp_version": "UNKNOWN",
                "db_name": "",
                "db_user": "",
                "db_host": "localhost",
                "table_prefix": "wp_",
                "plugins": 0,
                "themes": 0,
                "db_status": "SKIPPED",
            }
            vp = os.path.join(root, "wp-includes", "version.php")
            if os.path.isfile(vp):
                with open(vp, "r", encoding="utf-8", errors="replace") as fh:
                    m = re.search(r"\$wp_version\s*=\s*['\"]([^'\"]+)['\"]", fh.read())
                if m:
                    info["wp_version"] = m.group(1)

            with open(cfg_path, "r", encoding="utf-8", errors="replace") as fh:
                raw = fh.read()
            db_pass = ""
            for m in DEFINE_RX.finditer(raw):
                k, v = m.group(1), m.group(3)
                if k == "DB_NAME":
                    info["db_name"] = v
                elif k == "DB_USER":
                    info["db_user"] = v
                elif k == "DB_HOST":
                    info["db_host"] = v
                elif k == "DB_PASSWORD":
                    db_pass = v
            pm = PREFIX_RX.search(raw)
            if pm:
                info["table_prefix"] = pm.group(2)

            pdir = os.path.join(root, "wp-content", "plugins")
            tdir = os.path.join(root, "wp-content", "themes")
            if os.path.isdir(pdir):
                info["plugins"] = sum(1 for x in os.listdir(pdir) if os.path.isdir(os.path.join(pdir, x)))
            if os.path.isdir(tdir):
                info["themes"] = sum(1 for x in os.listdir(tdir) if os.path.isdir(os.path.join(tdir, x)))

            if args.check_db and mysql_bin and info["db_name"] and info["db_user"]:
                esc_pw = db_pass.replace("\\", "\\\\").replace('"', '\\"')
                fd, cnf = tempfile.mkstemp(prefix="sak_db_", suffix=".cnf")
                try:
                    os.chmod(cnf, 0o600)
                    with os.fdopen(fd, "w", encoding="utf-8") as fh:
                        fh.write(f'[client]\nuser="{info["db_user"]}"\npassword="{esc_pw}"\nhost="{info["db_host"]}"\n')
                    res = subprocess.run(
                        [mysql_bin, f"--defaults-extra-file={cnf}", "--connect-timeout=5", info["db_name"], "-e", "SELECT 1;"],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.PIPE,
                        text=True,
                        timeout=10,
                    )
                    info["db_status"] = "OK" if res.returncode == 0 else "FAILED"
                finally:
                    try:
                        os.unlink(cnf)
                    except OSError:
                        pass
            results.append(info)
    return results


def cmd_perms(args):
    target = os.path.abspath(args.path or os.getcwd())
    if not os.path.isdir(target):
        sys.stderr.write(f"Error: directory not found: {target}\n")
        sys.exit(1)

    changes = []
    sensitive = {"wp-config.php", ".env", ".htpasswd"}
    for root, dirs, files in os.walk(target, followlinks=False):
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules")]
        cur_mode = stat.S_IMODE(os.lstat(root).st_mode)
        if cur_mode != 0o755:
            changes.append({"type": "dir", "path": root, "old": oct(cur_mode), "new": "0o755", "applied": bool(args.fix)})
            if args.fix:
                os.chmod(root, 0o755)
        for fname in files:
            fpath = os.path.join(root, fname)
            if os.path.islink(fpath):
                continue
            fmode = stat.S_IMODE(os.lstat(fpath).st_mode)
            want = 0o600 if fname in sensitive else 0o644
            if fmode != want:
                changes.append({"type": "file", "path": fpath, "old": oct(fmode), "new": oct(want), "applied": bool(args.fix)})
                if args.fix:
                    os.chmod(fpath, want)
    return changes


def cmd_backup(args):
    target = os.path.abspath(args.path or os.getcwd())
    if not os.path.isdir(target):
        sys.stderr.write(f"Error: directory not found: {target}\n")
        sys.exit(1)
    bdir = os.path.abspath(args.backup_dir)
    os.makedirs(bdir, exist_ok=True)
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    label = re.sub(r"[^A-Za-z0-9_.-]+", "_", args.label or os.path.basename(target) or "backup")
    archive_path = os.path.join(bdir, f"sak-{label}-{ts}.tar.gz")

    file_count = 0
    with tarfile.open(archive_path, "w:gz") as tf:
        for root, dirs, files in os.walk(target, followlinks=False):
            dirs[:] = [d for d in dirs if d not in ("cache", "tmp", "node_modules")]
            for fname in files:
                fpath = os.path.join(root, fname)
                if not os.path.islink(fpath):
                    rel = os.path.relpath(fpath, target)
                    tf.add(fpath, arcname=rel)
                    file_count += 1
    os.chmod(archive_path, 0o600)

    h = hashlib.sha256()
    with open(archive_path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    manifest = {
        "archive": archive_path,
        "source": target,
        "files": file_count,
        "size_bytes": os.path.getsize(archive_path),
        "sha256": h.hexdigest(),
        "created_at": ts,
    }
    with open(archive_path + ".json", "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)
    os.chmod(archive_path + ".json", 0o600)
    return [manifest]


def cmd_restore(args):
    archive = os.path.abspath(args.archive)
    dest = os.path.abspath(args.path or os.getcwd())
    if not os.path.isfile(archive):
        sys.stderr.write(f"Error: archive not found: {archive}\n")
        sys.exit(1)
    os.makedirs(dest, exist_ok=True)
    extracted = 0
    with tarfile.open(archive, "r:gz") as tf:
        for member in tf.getmembers():
            member_path = os.path.abspath(os.path.join(dest, member.name))
            if not (member_path == dest or member_path.startswith(dest + os.sep)):
                raise RuntimeError(f"Blocked path traversal in archive: {member.name}")
        tf.extractall(dest)
        extracted = len(tf.getmembers())
    return [{"archive": archive, "destination": dest, "extracted": extracted, "status": "RESTORED"}]


def cmd_users(args):
    resellers = {}
    tuo = os.path.join(args.etc_root, "trueuserowners")
    if os.path.isfile(tuo):
        with open(tuo, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if ":" in line:
                    u, o = line.split(":", 1)
                    resellers[u.strip()] = o.strip()
    rows = []
    for pw in pwd.getpwall():
        if pw.pw_uid < args.min_uid or pw.pw_name == "nobody":
            continue
        owner = resellers.get(pw.pw_name, "-")
        if args.reseller and owner != args.reseller:
            continue
        rows.append({
            "username": pw.pw_name,
            "uid": pw.pw_uid,
            "gid": pw.pw_gid,
            "home": pw.pw_dir,
            "shell": pw.pw_shell,
            "owner": owner,
        })
    return rows


def render_output(subcmd, data, fmt, c):
    if fmt == "json":
        print(json.dumps(data, indent=2))
        return
    if fmt == "csv":
        buf = io.StringIO()
        if data:
            keys = list(data[0].keys())
            w = csv.DictWriter(buf, fieldnames=keys)
            w.writeheader()
            for row in data:
                w.writerow(row)
        sys.stdout.write(buf.getvalue())
        return

    print(f"{c.BOLD}{c.CYAN}=== sak.sh v{VERSION} | {subcmd} ==={c.RESET}")
    if not data:
        print("  (no items found)")
        return
    keys = list(data[0].keys())
    widths = {k: max(len(k), max(len(str(r.get(k, ""))) for r in data)) for k in keys}
    header = "  ".join(f"{k.upper():<{widths[k]}}" for k in keys)
    print(f"{c.BOLD}{header}{c.RESET}")
    print("-" * min(len(header), 110))
    for r in data:
        print("  ".join(f"{str(r.get(k, '')):<{widths[k]}}" for k in keys))


def main():
    parser = argparse.ArgumentParser(
        prog="sak.sh",
        description="Swiss Army Knife — CMS & cPanel Operations Toolkit CLI (v2.0.0)",
    )
    parser.add_argument("-v", "--version", action="version", version=f"sak.sh {VERSION}")
    sub = parser.add_subparsers(dest="subcommand", required=True)

    def add_common(p):
        p.add_argument("-o", "--output", choices=["table", "json", "csv"], default="table")
        p.add_argument("--no-color", action="store_true")
        p.add_argument("--etc-root", default="/etc")

    p_scan = sub.add_parser("scan", help="Detect CMS & web app installations offline")
    p_scan.add_argument("-p", "--path", help="Comma-separated paths")
    p_scan.add_argument("-u", "--user", help="Comma-separated users")
    p_scan.add_argument("-r", "--reseller", help="cPanel reseller")
    p_scan.add_argument("-m", "--maxdepth", type=int, default=3)
    add_common(p_scan)

    p_wp = sub.add_parser("wp-info", help="Audit WordPress installations & DB connectivity")
    p_wp.add_argument("-p", "--path", help="Comma-separated paths")
    p_wp.add_argument("-u", "--user", help="Comma-separated users")
    p_wp.add_argument("--check-db", action="store_true", help="Test MySQL/MariaDB login safely")
    add_common(p_wp)

    p_perms = sub.add_parser("perms", help="Audit or fix web permissions (755/644/600)")
    p_perms.add_argument("-p", "--path", help="Target directory (default: CWD)")
    p_perms.add_argument("--fix", action="store_true", help="Apply permission fixes")
    add_common(p_perms)

    p_bkp = sub.add_parser("backup", help="Create chmod 600 tar.gz backup + SHA-256 manifest")
    p_bkp.add_argument("-p", "--path", help="Source directory (default: CWD)")
    p_bkp.add_argument("-b", "--backup-dir", default="/var/backups/sak", help="Backup destination")
    p_bkp.add_argument("--label", help="Archive label")
    add_common(p_bkp)

    p_res = sub.add_parser("restore", help="Safely extract tar.gz backup archive")
    p_res.add_argument("-a", "--archive", required=True, help="Path to .tar.gz archive")
    p_res.add_argument("-p", "--path", help="Destination directory (default: CWD)")
    add_common(p_res)

    p_usr = sub.add_parser("users", help="List Linux/cPanel users & reseller owners")
    p_usr.add_argument("--min-uid", type=int, default=1000)
    p_usr.add_argument("-r", "--reseller", help="Filter by reseller owner")
    add_common(p_usr)

    args = parser.parse_args()
    handlers = {
        "scan": cmd_scan,
        "wp-info": cmd_wp_info,
        "perms": cmd_perms,
        "backup": cmd_backup,
        "restore": cmd_restore,
        "users": cmd_users,
    }
    data = handlers[args.subcommand](args)
    use_color = sys.stdout.isatty() and not args.no_color
    render_output(args.subcommand, data, args.output, Colors(enabled=use_color))


if __name__ == "__main__":
    main()
EOF

python3 -c "$PY_SCRIPT" "$@"
