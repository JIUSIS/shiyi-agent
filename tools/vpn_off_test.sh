#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
echo "== VPN gone? =="
dumpsys connectivity 2>/dev/null | grep -c "VPN CONNECTED"
echo "== loopback test (VPN off) =="
curl -s --max-time 4 -o /dev/null -w "lo3080=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
curl -s --max-time 4 -o /dev/null -w "lo9=%{http_code}\n" http://127.0.0.1:9/ 2>&1
curl -s --max-time 4 -o /dev/null -w "lo39999=%{http_code}\n" http://127.0.0.1:39999/ 2>&1
echo "== dsh still listening? =="
ss -tln 2>/dev/null | grep 3080 | head -2
