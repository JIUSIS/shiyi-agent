#!/system/bin/sh
# kill ALL node instances, start exactly one, wait, verify
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
# kill everything node-ish
for pid in $(ps -A | grep " node " | awk '{print $1}'); do
  kill -9 $pid 2>/dev/null
done
sleep 3
echo "== remaining node =="
ps -A | grep -E " node " | head -3
# start exactly one
nohup "$U/bin/node" --expose-internals "$U/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" web > "$P/tmp/dsh_single.log" 2>&1 &
echo "started $!"
sleep 18
echo "== listeners =="
cat /proc/net/tcp | grep -i :0C08 | grep -i " 0A " | head -3
echo "== root check =="
node -e 'const http=require("http");const req=http.get("http://127.0.0.1:3080/",r=>{console.log("root:",r.statusCode);r.resume();process.exit(0)});req.setTimeout(5000,()=>{console.log("TIMEOUT");process.exit(1)});req.on("error",e=>{console.log("ERR:",e.message);process.exit(1)})' 2>&1
echo "== log =="
tail -5 "$P/tmp/dsh_single.log"
