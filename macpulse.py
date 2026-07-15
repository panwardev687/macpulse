#!/usr/bin/env python3
"""macpulse - Mac temperature & performance monitor with history.

Commands:
  snapshot   Take one measurement, print it, and save to history (default)
  watch      Measure repeatedly every N seconds (Ctrl-C to stop)
  history    Show recent measurements
  stats      Min/avg/max summary over a time window
  export     Dump history to CSV

Temperatures are read via the bundled `sensors` binary (IOKit HID, no sudo).
History lives in ~/.macpulse/history.db (SQLite).
"""

import argparse
import datetime as dt
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SENSORS_BIN = os.path.join(HERE, "sensors")
DB_DIR = os.path.expanduser("~/.macpulse")
DB_PATH = os.path.join(DB_DIR, "history.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,                -- ISO timestamp, local time
    cpu_temp_max REAL,               -- hottest CPU die sensor (°C)
    cpu_temp_avg REAL,               -- average of CPU die sensors (°C)
    battery_temp REAL,               -- °C
    ssd_temp REAL,                   -- °C
    thermal_pressure TEXT,           -- Nominal/Moderate/Heavy/Trapping/Sleeping
    cpu_usage_pct REAL,              -- user+sys %
    load_1m REAL,
    mem_used_gb REAL,
    mem_total_gb REAL,
    mem_pressure_pct REAL,           -- free-percentage-derived pressure
    swap_used_gb REAL,
    disk_used_gb REAL,
    disk_total_gb REAL,
    battery_pct INTEGER,
    battery_state TEXT,              -- charging/discharging/charged
    battery_cycles INTEGER,
    battery_health_pct REAL,
    top_process TEXT,                -- heaviest process at sample time
    top_process_cpu REAL,
    sensors_json TEXT                -- full per-sensor temperature dump
);
CREATE INDEX IF NOT EXISTS idx_snapshots_ts ON snapshots(ts);
"""


def run(cmd, timeout=15):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return out.stdout
    except Exception:
        return ""


# ---------------------------------------------------------------- collectors

def read_temperatures():
    """Return (cpu_max, cpu_avg, battery, ssd, thermal_state, all_sensors dict)."""
    raw = run([SENSORS_BIN])
    try:
        sensors = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None, None, None, None, None, {}
    thermal_state = sensors.pop("_thermal_state", None)
    die = [v for k, v in sensors.items() if "tdie" in k.lower()]
    cpu_max = round(max(die), 1) if die else None
    cpu_avg = round(sum(die) / len(die), 1) if die else None
    battery = next((v for k, v in sensors.items() if "battery" in k.lower()), None)
    ssd = next((v for k, v in sensors.items() if "nand" in k.lower()), None)
    return cpu_max, cpu_avg, battery, ssd, thermal_state, sensors


def read_cpu_usage():
    """CPU busy % and 1-min load average."""
    out = run(["top", "-l", "2", "-n", "0", "-s", "1"], timeout=20)
    usage = None
    for line in out.splitlines():
        if line.startswith("CPU usage:"):
            m = re.search(r"([\d.]+)% user, ([\d.]+)% sys", line)
            if m:
                usage = round(float(m.group(1)) + float(m.group(2)), 1)
    load_1m = os.getloadavg()[0]
    return usage, round(load_1m, 2)


def read_memory():
    """Used/total GB, pressure %, swap used GB."""
    page_size = int(run(["sysctl", "-n", "hw.pagesize"]).strip() or 16384)
    total = int(run(["sysctl", "-n", "hw.memsize"]).strip() or 0)
    vm = run(["vm_stat"])
    pages = {m.group(1): int(m.group(2)) for m in re.finditer(r"^(.+?):\s+(\d+)\.", vm, re.M)}
    # "used" the way Activity Monitor counts it: active + wired + compressed
    used = (
        pages.get("Pages active", 0)
        + pages.get("Pages wired down", 0)
        + pages.get("Pages occupied by compressor", 0)
    ) * page_size
    # memory pressure = 100 - system-wide free percentage (what Activity Monitor graphs)
    mp = run(["memory_pressure", "-Q"])
    m = re.search(r"free percentage: (\d+)", mp)
    pressure = 100 - int(m.group(1)) if m else None
    swap = run(["sysctl", "-n", "vm.swapusage"])
    m = re.search(r"used = ([\d.]+)M", swap)
    swap_used_gb = round(float(m.group(1)) / 1024, 2) if m else None
    gb = 1024 ** 3
    return round(used / gb, 2), round(total / gb, 2), pressure, swap_used_gb


def read_disk():
    u = shutil.disk_usage("/")
    gb = 1024 ** 3
    return round(u.used / gb, 1), round(u.total / gb, 1)


def read_battery():
    """Percent, state, cycle count, health %."""
    out = run(["pmset", "-g", "batt"])
    pct = state = None
    m = re.search(r"(\d+)%;\s*(\w[\w ]*?);", out)
    if m:
        pct, state = int(m.group(1)), m.group(2).strip()
    ioreg = run(["ioreg", "-rn", "AppleSmartBattery"])
    cycles = health = None
    m = re.search(r'"CycleCount" = (\d+)', ioreg)
    if m:
        cycles = int(m.group(1))
    mx = re.search(r'"AppleRawMaxCapacity" = (\d+)', ioreg)
    dz = re.search(r'"DesignCapacity" = (\d+)', ioreg)
    if mx and dz and int(dz.group(1)):
        health = round(100 * int(mx.group(1)) / int(dz.group(1)), 1)
    return pct, state, cycles, health


def read_top_process():
    out = run(["ps", "-Aceo", "pcpu,comm", "-r"])
    lines = out.strip().splitlines()[1:2]
    if lines:
        parts = lines[0].strip().split(None, 1)
        if len(parts) == 2:
            return parts[1], float(parts[0])
    return None, None


def take_snapshot():
    cpu_max, cpu_avg, batt_temp, ssd_temp, thermal_state, sensors = read_temperatures()
    cpu_pct, load_1m = read_cpu_usage()
    mem_used, mem_total, mem_pressure, swap_used = read_memory()
    disk_used, disk_total = read_disk()
    batt_pct, batt_state, cycles, health = read_battery()
    top_name, top_cpu = read_top_process()
    return {
        "ts": dt.datetime.now().isoformat(timespec="seconds"),
        "cpu_temp_max": cpu_max,
        "cpu_temp_avg": cpu_avg,
        "battery_temp": batt_temp,
        "ssd_temp": ssd_temp,
        "thermal_pressure": thermal_state,
        "cpu_usage_pct": cpu_pct,
        "load_1m": load_1m,
        "mem_used_gb": mem_used,
        "mem_total_gb": mem_total,
        "mem_pressure_pct": mem_pressure,
        "swap_used_gb": swap_used,
        "disk_used_gb": disk_used,
        "disk_total_gb": disk_total,
        "battery_pct": batt_pct,
        "battery_state": batt_state,
        "battery_cycles": cycles,
        "battery_health_pct": health,
        "top_process": top_name,
        "top_process_cpu": top_cpu,
        "sensors_json": json.dumps(sensors),
    }


# ------------------------------------------------------------------- storage

def get_db():
    os.makedirs(DB_DIR, exist_ok=True)
    db = sqlite3.connect(DB_PATH)
    db.executescript(SCHEMA)
    return db


def save_snapshot(db, snap):
    cols = ", ".join(snap)
    marks = ", ".join("?" * len(snap))
    db.execute(f"INSERT INTO snapshots ({cols}) VALUES ({marks})", list(snap.values()))
    db.commit()


# ------------------------------------------------------------------- display

def temp_flag(t):
    if t is None:
        return ""
    if t >= 95:
        return " 🔥 HOT"
    if t >= 80:
        return " ⚠️  warm"
    return ""


def fmt(v, suffix="", none="–"):
    return f"{v}{suffix}" if v is not None else none


def print_snapshot(s):
    print(f"\n  macpulse · {s['ts']}")
    print("  " + "─" * 46)
    print(f"  CPU temp      {fmt(s['cpu_temp_max'], '°C')} max / {fmt(s['cpu_temp_avg'], '°C')} avg{temp_flag(s['cpu_temp_max'])}")
    print(f"  Battery temp  {fmt(s['battery_temp'], '°C')}     SSD temp  {fmt(s['ssd_temp'], '°C')}")
    print(f"  Thermal       {fmt(s['thermal_pressure'])}")
    print(f"  CPU usage     {fmt(s['cpu_usage_pct'], '%')}     load(1m)  {fmt(s['load_1m'])}")
    print(f"  Memory        {fmt(s['mem_used_gb'])} / {fmt(s['mem_total_gb'])} GB     swap  {fmt(s['swap_used_gb'], ' GB')}")
    print(f"  Disk          {fmt(s['disk_used_gb'])} / {fmt(s['disk_total_gb'])} GB")
    batt = f"{fmt(s['battery_pct'], '%')} ({fmt(s['battery_state'])})"
    print(f"  Battery       {batt}   cycles {fmt(s['battery_cycles'])}   health {fmt(s['battery_health_pct'], '%')}")
    print(f"  Top process   {fmt(s['top_process'])} ({fmt(s['top_process_cpu'], '% CPU')})")


# ------------------------------------------------------------------ commands

def cmd_snapshot(args):
    snap = take_snapshot()
    print_snapshot(snap)
    if not args.no_save:
        save_snapshot(get_db(), snap)
        print(f"\n  saved → {DB_PATH}")


def cmd_watch(args):
    db = get_db()
    print(f"watching every {args.interval}s - Ctrl-C to stop")
    try:
        while True:
            snap = take_snapshot()
            save_snapshot(db, snap)
            flag = temp_flag(snap["cpu_temp_max"])
            print(
                f"{snap['ts']}  cpu {fmt(snap['cpu_temp_max'],'°C'):>7}  "
                f"batt {fmt(snap['battery_temp'],'°C'):>7}  "
                f"usage {fmt(snap['cpu_usage_pct'],'%'):>6}  "
                f"mem {fmt(snap['mem_used_gb'])}/{fmt(snap['mem_total_gb'])}GB  "
                f"{fmt(snap['thermal_pressure'])}{flag}"
            )
            time.sleep(max(args.interval - 2, 1))  # top -l 2 itself takes ~2s
    except KeyboardInterrupt:
        print("\nstopped")


def _since(hours):
    return (dt.datetime.now() - dt.timedelta(hours=hours)).isoformat(timespec="seconds")


def cmd_history(args):
    db = get_db()
    q = "SELECT ts, cpu_temp_max, battery_temp, thermal_pressure, cpu_usage_pct, mem_used_gb, battery_pct, top_process FROM snapshots"
    params = []
    if args.hours:
        q += " WHERE ts >= ?"
        params.append(_since(args.hours))
    q += " ORDER BY ts DESC LIMIT ?"
    params.append(args.limit)
    rows = db.execute(q, params).fetchall()
    if not rows:
        print("no history yet - run `macpulse snapshot` or `macpulse watch` first")
        return
    print(f"\n  {'timestamp':<20} {'cpu°C':>6} {'batt°C':>7} {'therm':<9} {'cpu%':>6} {'memGB':>6} {'batt%':>6}  top process")
    print("  " + "─" * 92)
    for ts, ct, bt, tp, cu, mu, bp, proc in rows:
        print(f"  {ts:<20} {fmt(ct):>6} {fmt(bt):>7} {fmt(tp):<9} {fmt(cu):>6} {fmt(mu):>6} {fmt(bp):>6}  {fmt(proc)}")
    print(f"\n  {len(rows)} rows (newest first) · db: {DB_PATH}")


def cmd_stats(args):
    db = get_db()
    row = db.execute(
        """SELECT COUNT(*), MIN(ts), MAX(ts),
                  MIN(cpu_temp_max), AVG(cpu_temp_max), MAX(cpu_temp_max),
                  MIN(cpu_usage_pct), AVG(cpu_usage_pct), MAX(cpu_usage_pct),
                  AVG(mem_used_gb), MAX(mem_used_gb),
                  MIN(battery_temp), AVG(battery_temp), MAX(battery_temp)
           FROM snapshots WHERE ts >= ?""",
        [_since(args.hours)],
    ).fetchone()
    n = row[0]
    if not n:
        print(f"no measurements in the last {args.hours}h")
        return
    r = lambda v: round(v, 1) if v is not None else "–"
    print(f"\n  stats over last {args.hours}h · {n} measurements ({row[1]} → {row[2]})")
    print("  " + "─" * 52)
    print(f"  {'metric':<16} {'min':>8} {'avg':>8} {'max':>8}")
    print(f"  {'CPU temp °C':<16} {r(row[3]):>8} {r(row[4]):>8} {r(row[5]):>8}")
    print(f"  {'CPU usage %':<16} {r(row[6]):>8} {r(row[7]):>8} {r(row[8]):>8}")
    print(f"  {'Memory GB':<16} {'':>8} {r(row[9]):>8} {r(row[10]):>8}")
    print(f"  {'Battery °C':<16} {r(row[11]):>8} {r(row[12]):>8} {r(row[13]):>8}")
    hot = db.execute(
        "SELECT ts, cpu_temp_max, top_process FROM snapshots WHERE ts >= ? ORDER BY cpu_temp_max DESC LIMIT 1",
        [_since(args.hours)],
    ).fetchone()
    if hot and hot[1] is not None:
        print(f"\n  hottest moment: {hot[1]}°C at {hot[0]} (top process: {hot[2]})")


def read_process_heat(top_n=6):
    """CPU% aggregated by application (helper processes folded into their app)."""
    out = run(["ps", "-Aceo", "pcpu,comm"])
    apps = {}
    for line in out.strip().splitlines()[1:]:
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        try:
            pcpu = float(parts[0])
        except ValueError:
            continue
        # fold "Brave Browser Helper (Renderer)" etc. into "Brave Browser"
        app = re.sub(r" Helper.*$", "", parts[1])
        apps[app] = apps.get(app, 0) + pcpu
    ranked = sorted(apps.items(), key=lambda kv: -kv[1])
    return [(n, round(c, 1)) for n, c in ranked[:top_n] if c >= 1]


def cmd_why(args):
    cpu_max, cpu_avg, batt_temp, ssd_temp, thermal_state, _ = read_temperatures()
    cpu_pct, load_1m = read_cpu_usage()
    batt_pct, batt_state, _, _ = read_battery()
    procs = read_process_heat()

    print(f"\n  macpulse why · {dt.datetime.now().strftime('%H:%M:%S')}")
    print("  " + "─" * 50)
    print(f"  CPU {fmt(cpu_max, '°C')}{temp_flag(cpu_max)} · battery {fmt(batt_temp, '°C')} · thermal {fmt(thermal_state)} · CPU load {fmt(cpu_pct, '%')}")

    print("\n  Heat sources right now (CPU% by app):")
    if procs:
        peak = procs[0][1]
        for name, cpu in procs:
            bar = "█" * max(1, int(cpu / max(peak, 1) * 22))
            print(f"    {name[:34]:<34} {cpu:>6}%  {bar}")
    else:
        print("    nothing using meaningful CPU")

    # historical culprits: what was on top when the machine ran hotter than usual
    db = get_db()
    rows = db.execute(
        """SELECT top_process, COUNT(*) n, MAX(cpu_temp_max) peak
           FROM snapshots
           WHERE ts >= ? AND cpu_temp_max >= (
               SELECT AVG(cpu_temp_max) + 2 FROM snapshots WHERE ts >= ?)
           GROUP BY top_process ORDER BY n DESC LIMIT 5""",
        [_since(args.hours), _since(args.hours)],
    ).fetchall()
    if rows:
        print(f"\n  Historical culprits (top process during hot samples, last {args.hours:g}h):")
        for name, n, peak in rows:
            print(f"    {str(name)[:34]:<34} {n:>3} hot samples · peaked {peak}°C")

    # verdict: workload vs environment
    print("\n  Verdict:")
    reasons = []
    if cpu_pct is not None and cpu_pct >= 50:
        who = ", ".join(n for n, _ in procs[:3]) or "processes above"
        reasons.append(f"workload-driven - CPU is {cpu_pct}% busy; main load: {who}")
    elif cpu_pct is not None and cpu_pct >= 20 and cpu_max is not None and cpu_max >= 70:
        reasons.append(f"partly workload - moderate CPU load ({cpu_pct}%); see apps above")
    if batt_state == "charging":
        reasons.append("charging adds several °C of case/battery heat")
    if batt_temp is not None and batt_temp >= 38:
        reasons.append(
            f"battery at {batt_temp}°C - warm environment, direct sun, or a soft surface "
            "blocking airflow (battery temp tracks surroundings, not CPU spikes)"
        )
    if cpu_max is not None and cpu_max >= 75 and (cpu_pct or 0) < 20 and not reasons:
        reasons.append("chip is hot but CPU is idle - likely GPU/media work, charging, or a hot environment")
    if procs and procs[0][1] >= 80 and not any("workload" in r for r in reasons):
        reasons.append(
            f"{procs[0][0]} is burning {procs[0][1]}% of a core on its own - "
            "the biggest single heat source even though overall load looks low"
        )
    if not reasons:
        if cpu_max is not None and cpu_max < 60:
            reasons.append(f"nothing to blame - {cpu_max}°C is a normal temperature")
        else:
            reasons.append("mixed/light load; nothing stands out")
    for r in reasons:
        print(f"    • {r}")
    if thermal_state and thermal_state != "Nominal":
        print(f"    • macOS thermal state is {thermal_state} - the system is actively slowing down to shed heat")
    print()


def cmd_dashboard(args):
    import http.server
    import threading

    html_path = os.path.join(HERE, "dashboard.html")

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _json(self, obj):
            body = json.dumps(obj).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            from urllib.parse import urlparse, parse_qs

            url = urlparse(self.path)
            if url.path == "/":
                with open(html_path, "rb") as f:
                    body = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif url.path == "/api/current":
                snap = take_snapshot()
                save_snapshot(sqlite3.connect(DB_PATH), snap)
                snap.pop("sensors_json", None)
                self._json(snap)
            elif url.path == "/api/history":
                hours = float(parse_qs(url.query).get("hours", ["6"])[0])
                db = sqlite3.connect(DB_PATH)
                cur = db.execute(
                    """SELECT ts, cpu_temp_max, battery_temp, ssd_temp, cpu_usage_pct,
                              mem_used_gb, swap_used_gb, mem_total_gb, thermal_pressure
                       FROM snapshots WHERE ts >= ? ORDER BY ts""",
                    [_since(hours)],
                )
                cols = [d[0] for d in cur.description]
                self._json([dict(zip(cols, r)) for r in cur])
            else:
                self.send_error(404)

    get_db().close()  # ensure schema exists
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = f"http://127.0.0.1:{args.port}"
    print(f"macpulse dashboard → {url}  (Ctrl-C to stop)")
    if not args.no_open:
        threading.Timer(0.4, lambda: subprocess.run(["open", url])).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


def cmd_export(args):
    import csv

    db = get_db()
    cur = db.execute("SELECT * FROM snapshots ORDER BY ts")
    cols = [d[0] for d in cur.description]
    with open(args.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        w.writerows(cur)
    print(f"exported → {args.out}")


def main():
    p = argparse.ArgumentParser(prog="macpulse", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd")

    s = sub.add_parser("snapshot", help="take one measurement and save it")
    s.add_argument("--no-save", action="store_true", help="print only, don't record")

    w = sub.add_parser("watch", help="measure continuously")
    w.add_argument("-i", "--interval", type=int, default=30, help="seconds between samples (default 30)")

    h = sub.add_parser("history", help="show recent measurements")
    h.add_argument("-n", "--limit", type=int, default=20)
    h.add_argument("--hours", type=float, help="only show last N hours")

    st = sub.add_parser("stats", help="min/avg/max summary")
    st.add_argument("--hours", type=float, default=24)

    e = sub.add_parser("export", help="dump history to CSV")
    e.add_argument("-o", "--out", default="macpulse_history.csv")

    d = sub.add_parser("dashboard", help="live dashboard in your browser")
    d.add_argument("-p", "--port", type=int, default=8321)
    d.add_argument("--no-open", action="store_true", help="don't auto-open the browser")

    y = sub.add_parser("why", help="diagnose what's causing current heat")
    y.add_argument("--hours", type=float, default=24, help="history window for culprit analysis")

    args = p.parse_args()
    if not os.path.exists(SENSORS_BIN):
        sys.exit("sensors binary missing - build it with: swiftc -O sensors.swift -o sensors")
    {
        None: cmd_snapshot,
        "snapshot": cmd_snapshot,
        "watch": cmd_watch,
        "history": cmd_history,
        "stats": cmd_stats,
        "export": cmd_export,
        "dashboard": cmd_dashboard,
        "why": cmd_why,
    }[args.cmd](args if args.cmd else argparse.Namespace(no_save=False))


if __name__ == "__main__":
    main()
