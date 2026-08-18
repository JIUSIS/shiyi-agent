#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
echo "== VPN still up? =="
dumpsys connectivity 2>/dev/null | grep -c "VPN CONNECTED"
echo "== dsh listener =="
ss -tln 2>/dev/null | grep 3080 | head -2
echo "== connectivity check (no proxy) =="
curl -s --max-time 5 -o /dev/null -w "npmmirror=%{http_code}\n" https://registry.npmmirror.com/ 2>&1
curl -s --max-time 5 -o /dev/null -w "aliyun=%{http_code}\n" https://mirrors.aliyun.com/ 2>&1
echo "== kill old dsh (network binding stale) =="
pkill -9 -f "bin.js" 2>/dev/null
sleep 2
echo "== fresh start dsh =="
nohup "$U/bin/node" --expose-internals "$U/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" web > "$P/tmp/dsh_direct.log" 2>&1 &
echo "started $!"
sleep 15
echo "== listener =="
ss -tln 2>/dev/null | grep 3080 | head -2
echo "== app check =="
node -e 'const http=require("http");const req=http.get("http://127.0.0.1:3080/",r=>{console.log("lo:",r.statusCode);r.resume();process.exit(0)});req.setTimeout(4000,()=>{console.log("lo TIMEOUT");process.exit(1)});req.on("error",e=>{console.log("lo ERR:",e.message);process.exit(1)})' 2>&1
echo "== log =="
tail -3 "$P/tmp/dsh_direct.log"
