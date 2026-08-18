#!/system/bin/sh
echo "== node procs =="
ps -A -o PID,PPID,UID,STATE 2>/dev/null | grep -E "node" | head -6
echo "== tcp 3080 =="
cat /proc/net/tcp 2>/dev/null | grep -i "0C08" | head -6
echo "== bin.js owners =="
for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
  if tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q "bin.js"; then
    echo "PID $p: $(cat /proc/$p/status 2>/dev/null | grep -E 'State|Name' | tr '\n' ' ')"
  fi
done
echo DONE
