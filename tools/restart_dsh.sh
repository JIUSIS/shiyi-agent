#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
pkill -9 -f "bin.js" 2>/dev/null
sleep 2
ps -A | grep -E " node " | head -3
nohup "$U/bin/node" --expose-internals "$U/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" web > "$P/tmp/domains.log" 2>&1 &
echo "started $!"
for i in $(seq 1 40); do
  if node -e 'require("http").get("http://127.0.0.1:3080/",r=>process.exit(0)).on("error",()=>process.exit(1))' 2>/dev/null; then
    echo "READY after ${i}s"
    node -e 'require("http").get("http://127.0.0.1:3080/",r=>console.log("root:",r.statusCode)).on("error",e=>console.log("ERR:",e.message))' 2>&1
    exit 0
  fi
  sleep 1
done
echo "NOT READY"
tail -8 "$P/tmp/domains.log"
exit 1
