#!/system/bin/sh
echo "== ss listen queue =="
ss -tlnp 2>/dev/null | grep 3080
echo "== ss full =="
ss -tan 2>/dev/null | grep 3080 | head -12
echo "== syncookies =="
cat /proc/sys/net/ipv4/tcp_syncookies 2>/dev/null
echo "== somaxconn =="
cat /proc/sys/net/core/somaxconn 2>/dev/null
echo "== try connect with small queue test: port 3080 from adb shell (uid shell) =="
echo "test" | timeout 3 nc 127.0.0.1 3080 2>&1 | head -2
echo "nc rc=$?"
echo "== ipv6? =="
cat /proc/net/tcp6 2>/dev/null | grep -i 0C08 | head -3
