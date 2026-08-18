#!/system/bin/sh
echo "== root ss 3080 =="
ss -tlnp 2>/dev/null | grep 3080 | head -3
echo "== all node procs =="
ps -A -o PID,PPID,UID,STATE 2>/dev/null | grep -E "node" | head -8
echo "== inode owner of 3080 =="
INODE=$(cat /proc/net/tcp 2>/dev/null | grep -i "0100007F:0C08" | grep -i " 0A " | awk '{print $10}' | head -1)
echo "inode=$INODE"
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  ls -l /proc/$p/fd 2>/dev/null | grep -q "$INODE" && echo "owned by pid $p: $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | head -c 80)"
done
echo "== kill ALL node =="
pkill -9 -f "node" 2>/dev/null
sleep 2
echo "== after =="
ps -A -o PID,PPID,UID,STATE 2>/dev/null | grep -E "node" | head -4
cat /proc/net/tcp 2>/dev/null | grep -i "0100007F:0C08" | grep -i " 0A " | head -2
echo "CLEAN"
