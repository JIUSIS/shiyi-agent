#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
echo "== full log wc =="
wc -l "$P/tmp/dsh_single.log"
echo "== tail 20 =="
tail -20 "$P/tmp/dsh_single.log"
echo "== dmesg lmk kills =="
dmesg 2>/dev/null | grep -iE "lowmemorykiller|kill.*node|30890" | tail -5
echo "== start again with nohup+disown =="
nohup "$U/bin/node" --expose-internals "$U/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" web > "$P/tmp/dsh_again.log" 2>&1 &
DPID=$!
disown 2>/dev/null
echo "pid=$DPID"
sleep 8
echo "== alive? =="
kill -0 $DPID 2>/dev/null && echo "ALIVE" || echo "DEAD"
ps -A | grep " node " | head -3
tail -3 "$P/tmp/dsh_again.log"
