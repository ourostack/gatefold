#!/bin/sh
# Samples what makes the runner's load (gatefold#39, #404, #487), every <interval> seconds for the whole job:
#   ci-load-sample.sh <out file> [interval]   run in the background
# The load average counts runnable threads, not busy CPUs: these runners have 3 CPUs (`cpus` below), so a load of 450
# means about 150 threads waiting for each CPU, and the busiest processes by %CPU (the 8 lines under each `==`) can't
# say whose threads those are. So each sample also counts the runnable threads by process, and splits the CPU between
# the host and the simulator (a process whose path is inside a simulator runtime or device). Every process with a
# runnable thread goes to <out file>.threads, one line a sample, for the long tail the 8 busiest leave out. Names and
# numbers only.
set -u
out="$1"
every="${2:-20}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ci-load-sample.XXXXXX")"
echo "== cpus $(sysctl -n hw.ncpu) ($(sysctl -n hw.physicalcpu) physical), memory $(($(sysctl -n hw.memsize) / 1073741824)) GB" >> "$out"
while :; do
  {
    echo "== $(date -u +%T) $(sysctl -n vm.loadavg)"
    # Memory beside the load (gatefold#404): a 7 GB runner that swaps looks like a frozen CPU. Free memory (percent,
    # the system's own figure), swap in use, the pages compressed and swapped out so far, and the processes' total RSS.
    echo "memory: free $(sysctl -n kern.memorystatus_level 2>/dev/null || echo ?)%, swap $(sysctl -n vm.swapusage 2>/dev/null | sed 's/.*used = \([0-9.]*M\).*/\1/'), $(vm_stat 2>/dev/null | awk '/Pages occupied by compressor/ { c = $NF + 0 } /Swapouts/ { s = $NF + 0 } END { printf "compressor %d pages, swapouts %d", c, s }'), rss $(ps -Ao rss= | awk '{ t += $1 } END { printf "%d MB", t / 1024 }')"
    ps -Aceo pcpu=,rss=,comm= -r | head -8
    ps -Ao pid=,pcpu=,comm= > "$tmp/procs"
    # One line per thread; its last two fields are the process and the thread's state (R runnable, U blocked).
    ps -AM -o pid=,state= > "$tmp/threads"
    awk -v ncpu="$(sysctl -n hw.ncpu)" -v top="$tmp/top" '
      FNR == NR {
        pid = $1; cpu = $2
        sub(/^ *[0-9]+ +[0-9.]+ +/, "")
        name = $0; sub(/.*\//, "", name); names[pid] = name
        sim[pid] = $0 ~ /RuntimeRoot\/|CoreSimulator\/Devices\//
        procs++; sprocs += sim[pid]
        if (sim[pid]) scpu += cpu; else hcpu += cpu
        next
      }
      FNR > 1 {
        pid = $(NF - 1); all++
        if ($NF ~ /^R/) { run++; if (!byproc[pid]++) { rprocs++; if (sim[pid]) srprocs++ }; if (sim[pid]) srun++ }
        else if ($NF ~ /^U/) blocked++
      }
      END {
        printf "cpu: host %d%%, simulator %d%% of %d%%; threads %d, runnable %d (simulator %d), blocked %d\n",
          hcpu, scpu, ncpu * 100, all, run, srun, blocked
        printf "processes: %d (simulator %d), with a runnable thread %d (simulator %d)\n", procs, sprocs, rprocs, srprocs
        for (p in byproc) printf "%d %s%s\n", byproc[p], (p in names ? names[p] : p), (sim[p] ? "*" : "") > top
      }' "$tmp/procs" "$tmp/threads"
    { printf "%s" "$(date -u +%T)"; sort -rn "$tmp/top" 2>/dev/null | awk '{ $1 = $1; printf " %s,", $0 }' | sed 's/,$//'; echo; } >> "$out.threads"
    printf "runnable threads (* in the simulator):"
    sort -rn "$tmp/top" 2>/dev/null | head -8 | awk '{ $1 = $1; printf " %s,", $0 }' | sed 's/,$//'
    echo
    : > "$tmp/top"
  } >> "$out" 2>&1
  sleep "$every"
done
