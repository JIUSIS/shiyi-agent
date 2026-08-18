#!/system/bin/sh
echo "== listeners on 3080 =="
cat /proc/net/tcp 2>/dev/null | awk 'NR==1 || /:0C08/' | head -5
echo "== node processes =="
ps -A -o PID,PPID,NAME,CMD 2>/dev/null | grep -E "node|dsh" | head -8
echo "== connectivity from app uid =="
su 10490 -c 'cat /proc/net/tcp' 2>/dev/null | grep -i ":0C08" | head -3
