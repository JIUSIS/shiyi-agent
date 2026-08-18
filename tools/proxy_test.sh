#!/system/bin/sh
echo "== curl 3080 via FlClash proxy (bypass 127.* so should fail differently) =="
curl -s --max-time 4 -x http://127.0.0.1:7890 -o /dev/null -w "proxy3080=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
echo "== curl 3080 direct again =="
curl -s --max-time 4 -o /dev/null -w "direct=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
echo "== mark.via conn: check if it's live (rx/tx bytes changing) =="
cat /proc/net/tcp 2>/dev/null | grep -i "0C08" | grep " 01 " | head -3
echo "== who are mark.via connections from? sockets in 10890 =="
ls -la /proc/10890/fd 2>/dev/null | grep -c socket
echo "== dsh service log again =="
tail -5 /data/user/0/com.shiyi.agent/files/termux/tmp/dsh_single.log 2>&1
echo "== check FlClash access control per-app? =="
cat /data/user/0/com.follow.clash.dev/shared_prefs/FlutterSharedPreferences.xml 2>/dev/null | grep -oE "accessControlProps[^}]*}" | head -2
