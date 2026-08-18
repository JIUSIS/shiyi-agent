#!/system/bin/sh
echo "== ALL node procs (root) =="
ps -A -o PID,PPID,NAME,STATE 2>/dev/null | grep -E "node|PID" | head -10
echo "== kill all node =="
pkill -9 -f "node" 2>/dev/null
pkill -9 -f "dsh" 2>/dev/null
sleep 3
echo "== after kill =="
ps -A -o PID,PPID,NAME,STATE 2>/dev/null | grep -E "node|PID" | head -6
echo "== tcp 3080 =="
cat /proc/net/tcp 2>/dev/null | grep -i ":0C08" | head -5
echo "== port 3080 free check: try listen =="
# use a raw listener test via node if available; else netcat absence is fine
echo "DONE"
