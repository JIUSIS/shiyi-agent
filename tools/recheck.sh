#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
echo "== proc =="
ps -A | grep " node " | head -3
echo "== try connect 5x =="
for i in 1 2 3 4 5; do
  node -e 'const http=require("http");const req=http.get("http://127.0.0.1:3080/",r=>{console.log("try '$i':",r.statusCode);r.resume();process.exit(0)});req.setTimeout(3000,()=>{console.log("try '$i': TIMEOUT");process.exit(1)});req.on("error",e=>{console.log("try '$i':",e.message);process.exit(1)})' 2>&1
  sleep 1
done
echo "== log =="
tail -8 "$P/tmp/dsh_single.log"
