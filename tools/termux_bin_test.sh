#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
echo "== termux bash /dev/tcp 3080 =="
timeout 5 "$U/bin/bash" -c 'exec 3<>/dev/tcp/127.0.0.1/3080 && echo TCP_OK || echo TCP_FAIL' 2>&1
echo "== system nc 3080 =="
(echo -e "GET / HTTP/1.0\r\n\r"; sleep 1) | timeout 5 nc 127.0.0.1 3080 2>&1 | head -3
echo "== termux curl via proxy 7890 (control: external) =="
curl -s --max-time 5 -o /dev/null -w "ext223=%{http_code}\n" http://223.5.5.5/ 2>&1
echo "== termux python? =="
ls "$U/bin/python"* 2>/dev/null | head -2
