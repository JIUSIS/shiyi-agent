#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
echo "== root: listener =="
ss -tlnp 2>/dev/null | grep 3080 | head -2
echo "== wait 10 more sec =="
sleep 10
echo "== root: listener again =="
ss -tlnp 2>/dev/null | grep 3080 | head -2
echo "== dsh log full =="
cat "$P/tmp/dsh_direct.log"
echo "== ip rule head =="
ip rule show 2>/dev/null | head -6
