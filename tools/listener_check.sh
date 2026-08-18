#!/system/bin/sh
echo "== listener with pid =="
ss -tlnp 2>/dev/null | grep 3080
echo "== all node procs now =="
ps -A -o PID,PPID,UID,STATE 2>/dev/null | grep -E " node |node$" | head -6
echo "== find 3080 socket inode owner =="
INODE=$(cat /proc/net/tcp 2>/dev/null | grep -i "0100007F:0C08" | grep -i " 0A " | awk '{print $10}' | head -1)
echo "inode=$INODE"
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  ls -l /proc/$p/fd 2>/dev/null | grep -q "$INODE" && echo "owned by pid $p"
done
echo "== proc 31585 status =="
cat /proc/31585/status 2>/dev/null | grep -E "State|Name|Uid" | head -4
echo "== cgroup freeze of 31585 =="
CG=$(cat /proc/31585/cgroup 2>/dev/null | grep "^0::" | cut -d: -f3)
echo "cgroup=$CG"
[ -n "$CG" ] && cat "/sys/fs/cgroup$CG/cgroup.freeze" 2>/dev/null && echo " <- freeze value"
