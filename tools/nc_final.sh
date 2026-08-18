#!/system/bin/sh
echo "== dsh proc =="
ps -A -o PID,PPID,UID,STATE 2>/dev/null | grep node | head -4
echo "== nc 3080 =="
(echo -e "GET / HTTP/1.0\r\n\r"; sleep 1) | timeout 5 nc 127.0.0.1 3080 2>&1 | head -5
echo "nc rc=$?"
echo "== nc 9 =="
(echo "x") | timeout 3 nc 127.0.0.1 9 2>&1 | head -2
echo "nc9 rc=$?"
echo "== ls listener again =="
ss -tln 2>/dev/null | grep 3080 | head -2
