#!/bin/sh
# Container CPU (cgroup v2 usage over an interval, % of one core) and memory (memory.current, and anon), plus
# per-process CPU in the browser container. Usage: measure.sh <container> <seconds> <label>
c=$1; secs=$2; label=$3
read_cg() { docker exec "$c" sh -c 'sed -n "s/^usage_usec //p" /sys/fs/cgroup/cpu.stat; cat /sys/fs/cgroup/memory.current; sed -n "s/^anon //p" /sys/fs/cgroup/memory.stat'; }
procs() { docker exec "$c" sh -c 'ps -eo cputimes=,comm= 2>/dev/null || ps -eo time=,comm='; }
set -- $(read_cg); u0=$1
p0=$(procs)
sleep "$secs"
set -- $(read_cg); u1=$1; mem=$2; anon=$3
p1=$(procs)
python3 -I - "$label" "$c" "$secs" "$u0" "$u1" "$mem" "$anon" "$p0" "$p1" <<'PY'
import sys, json, collections
label, c, secs, u0, u1, mem, anon, p0, p1 = sys.argv[1:]
def agg(t):
    d = collections.Counter()
    for line in t.strip().splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[0].isdigit(): d[parts[1].split('/')[0][:15]] += int(parts[0])
    return d
a, b = agg(p0), agg(p1)
per = {k: round((b[k] - a.get(k, 0)) / float(secs) * 100, 1) for k in b if b[k] - a.get(k, 0) > 0}
print(json.dumps({"label": label, "container": c, "seconds": float(secs),
                  "cpu_percent_of_one_core": round((int(u1) - int(u0)) / 1e6 / float(secs) * 100, 1),
                  "memory_current_mib": round(int(mem) / 2**20), "anon_mib": round(int(anon) / 2**20),
                  "per_process_cpu_percent": per}))
PY
