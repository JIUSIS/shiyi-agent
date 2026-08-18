#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
echo "== confirm old dsh dead =="
INODE=$(cat /proc/net/tcp 2>/dev/null | grep -i "0100007F:0C08" | grep -i " 0A " | awk '{print $10}' | head -1)
echo "listener inode: $INODE (empty = free)"
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  ls -l /proc/$p/fd 2>/dev/null | grep -q "$INODE" && echo "STILL: $p"
done
echo "== start fresh dsh (new VPN network) =="
nohup "$U/bin/node" --expose-internals "$U/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" web > "$P/tmp/dsh_new.log" 2>&1 &
echo "started $!"
sleep 16
echo "== listener =="
ss -tln 2>/dev/null | grep 3080 | head -2
echo "== root check =="
curl -s --max-time 4 -o /dev/null -w "root_lo3080=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
echo "== app check =="
node -e 'const http=require("http");const req=http.get("http://127.0.0.1:3080/",r=>{console.log("app_lo:",r.statusCode);r.resume();process.exit(0)});req.setTimeout(4000,()=>{console.log("app_lo TIMEOUT");process.exit(1)});req.on("error",e=>{console.log("app_lo ERR:",e.message);process.exit(1)})' 2>&1
echo "== log =="
tail -3 "$P/tmp/dsh_new.log"
