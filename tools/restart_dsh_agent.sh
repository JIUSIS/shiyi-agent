#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
# 确保 agent 目录存在
mkdir -p /storage/emulated/0/agent
echo "== agent dir =="
ls -ld /storage/emulated/0/agent
echo "== start dsh with cwd=agent =="
cd /storage/emulated/0/agent
nohup "$U/bin/node" --expose-internals "$U/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" web > "$P/tmp/dsh_agent.log" 2>&1 &
echo "started $!"
sleep 14
echo "== listener =="
ss -tln 2>/dev/null | grep 3080 | head -2
echo "== host.describe cwd =="
node -e '
const http=require("http");
const body=JSON.stringify({type:"client-request",rpcId:"1",method:"host.describe",payload:{}});
const req=http.request({host:"127.0.0.1",port:3080,path:"/api/host.describe",method:"POST",headers:{"Content-Type":"application/json","Content-Length":Buffer.byteLength(body)}},r=>{
  let d="";r.on("data",c=>d+=c);r.on("end",()=>{try{const j=JSON.parse(d);console.log("cwd:",j.result&&j.result.ok?j.result.value.cwd:JSON.stringify(j).slice(0,200));}catch(e){console.log("parse:",d.slice(0,200));}});
});
req.setTimeout(6000,()=>{req.destroy();console.log("TIMEOUT");});
req.on("error",e=>console.log("ERR:",e.message));
req.end(body);
' 2>&1
echo "== listDirectory agent =="
node -e '
const http=require("http");
const body=JSON.stringify({type:"client-request",rpcId:"2",method:"host.listDirectory",payload:{path:"/storage/emulated/0/agent"}});
const req=http.request({host:"127.0.0.1",port:3080,path:"/api/host.listDirectory",method:"POST",headers:{"Content-Type":"application/json","Content-Length":Buffer.byteLength(body)}},r=>{
  let d="";r.on("data",c=>d+=c);r.on("end",()=>{try{const j=JSON.parse(d);console.log("items:",j.result&&j.result.ok?(j.result.value.items||[]).length:JSON.stringify(j).slice(0,200));}catch(e){console.log("parse:",d.slice(0,200));}});
});
req.setTimeout(6000,()=>{req.destroy();console.log("TIMEOUT");});
req.on("error",e=>console.log("ERR:",e.message));
req.end(body);
' 2>&1
echo "== log =="
tail -2 "$P/tmp/dsh_agent.log"
