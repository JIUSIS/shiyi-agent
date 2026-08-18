#!/system/bin/sh
echo "== dsh proc 31585 cgroup =="
cat /proc/31585/cgroup 2>/dev/null | head -8
echo "== freezer state =="
for f in /sys/fs/cgroup/*/cgroup.freeze /sys/fs/cgroup/cgroup.freeze; do
  [ -f "$f" ] && echo "$f: $(cat $f 2>/dev/null)"
done 2>/dev/null | head -20
echo "== proc state detail =="
cat /proc/31585/status 2>/dev/null | grep -E "State|Name|Pid|TracerPid" | head -6
echo "== wchan =="
cat /proc/31585/wchan 2>/dev/null
echo "== socket backlog / listen info =="
cat /proc/31585/net/tcp 2>/dev/null | grep -i 0C08 | head -3
echo "== try kill frozen and restart? first check all node =="
ps -A -o PID,PPID,UID,STATE 2>/dev/null | grep node | head -5
