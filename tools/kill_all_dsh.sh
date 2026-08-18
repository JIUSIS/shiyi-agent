#!/system/bin/sh
echo "== all node procs (root view) =="
ps -A -o PID,PPID,UID,NAME 2>/dev/null | grep -E "node" | head -10
echo "== who owns 3080 =="
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  if [ -r /proc/$p/cmdline ] 2>/dev/null; then
    if tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q "bin.js"; then
      echo "PID $p: $(tr '\0' ' ' < /proc/$p/cmdline | head -c 120)"
    fi
  fi
done
echo "== kill all bin.js owners =="
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  if [ -r /proc/$p/cmdline ] 2>/dev/null; then
    if tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q "bin.js"; then
      kill -9 $p 2>/dev/null && echo "killed $p"
    fi
  fi
done
sleep 2
echo "== remaining =="
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  if [ -r /proc/$p/cmdline ] 2>/dev/null; then
    if tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q "bin.js"; then
      echo "STILL: $p"
    fi
  fi
done
echo "DONE"
