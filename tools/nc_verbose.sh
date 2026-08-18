#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
echo "== nc -v to 39999 (verbose, 4s) =="
timeout 4 nc -v -w 3 127.0.0.1 39999 2>&1
echo "rc=$?"
echo "== ss right after =="
ss -tan 2>/dev/null | grep 39999 | head -4
echo "== tcpdump lo 39999 during nc =="
timeout 5 tcpdump -i lo -c 8 "port 39999" 2>&1 | head -10 &
sleep 1
timeout 3 nc -v -w 2 127.0.0.1 39999 2>&1
wait
echo "== check proc temp server alive =="
cat /proc/23439/status 2>/dev/null | grep -E "State|Name" | head -3
