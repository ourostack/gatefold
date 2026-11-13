#!/bin/sh
# Samples every thread of the app, and of the processes busiest beside it, while its main thread is held
# (gatefold#357). The app's own watch (Gatefold/App/MainThreadWatch.swift) samples main only, and only on a tick
# the process was run: a hold where main waits on another thread, or the whole process is starved, logs no cause.
# A simulator's processes are the host's, so the host can sample them. Stacks only: no page text.
#   ci-hang-sample.sh <reader.log> <out dir>   run in the background for the whole test step
# Once a hold passes 30 s, and again past 5 min: the app (sample, and spindump's blocked-by notes when sudo needs no
# password), SpringBoard and the three busiest WebContent processes. At most 4 rounds a job.
set -u
log="$1"
out="$2"
mkdir -p "$out"
rounds=0
mark=0 # 0: no round yet this hold; 1: the 30 s round taken; 2: the 5 min round taken
snap() {
  rounds=$((rounds + 1))
  dir="$out/hold-$rounds-$1ms"
  mkdir -p "$dir"
  {
    date -u +%T
    sysctl -n vm.loadavg
    ps -Aceo pid=,pcpu=,rss=,state=,comm= -r | head -25
  } > "$dir/ps.txt" 2>&1
  app="$(pgrep -x Gatefold | head -1)"
  if [ -n "$app" ]; then
    sample "$app" 3 -file "$dir/gatefold.sample.txt" > /dev/null 2>&1 &
    sudo -n spindump "$app" 3 -file "$dir/gatefold.spindump.txt" > /dev/null 2>&1 &
  fi
  board="$(pgrep -x SpringBoard | head -1)"
  if [ -n "$board" ]; then sample "$board" 3 -file "$dir/springboard.sample.txt" > /dev/null 2>&1 & fi
  ps -Aceo pid=,pcpu=,comm= -r | awk '$3 == "com.apple.WebKit.WebContent" { print $1 }' | head -3 | {
    while read -r web; do sample "$web" 3 -file "$dir/webcontent-$web.sample.txt" > /dev/null 2>&1 & done
    wait
  } &
  wait
  echo "$(date -u +%T) hang sample $rounds at $1 ms: $dir"
}
tail -n 0 -F "$log" 2> /dev/null | while IFS= read -r line; do
  case "$line" in
    *"main: held "*) mark=0; continue ;;
    *"main: still held after "*) ;;
    *) continue ;;
  esac
  [ "$rounds" -lt 4 ] || continue
  ms="$(printf '%s\n' "$line" | sed -n -E 's/.*still held after ([0-9]+) ms.*/\1/p')"
  [ -n "$ms" ] || continue
  if [ "$mark" -eq 0 ] && [ "$ms" -ge 30000 ]; then
    mark=1
    snap "$ms"
  elif [ "$mark" -eq 1 ] && [ "$ms" -ge 300000 ]; then
    mark=2
    snap "$ms"
  fi
done
