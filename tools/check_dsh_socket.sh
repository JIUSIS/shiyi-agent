#!/system/bin/sh
echo "== dsh node process =="
ps -A -o PID,PPID,STAT,NAME | grep -E "node|dsh" | grep -v grep
echo "== listen 3080 =="
ss -ltnp 2>/dev/null | grep 3080
echo "== socket detail =="
ss -ltnp 2>/dev/null | grep -A1 "State"
echo "== syn queue stats for 3080 =="
ss -ltn 2>/dev/null | grep 3080
echo "== dmesg tail (tcp) =="
dmesg 2>/dev/null | tail -20 | grep -iE "tcp|drop|listen|syn" 
echo "== tcp sysctls =="
cat /proc/sys/net/ipv4/tcp_syncookies 2>/dev/null
cat /proc/sys/net/ipv4/tcp_max_syn_backlog 2>/dev/null
echo "== any frozen processes in dsh cgroup =="
cat /proc/28667/status 2>/dev/null | grep -E "State|SigBlk|SigCgt"
