#!/system/bin/sh
# probe exact payloads for skill.list / session.search / credentials.describe
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
node -e '
const http=require("http");
function rpc(method,payload){return new Promise((res)=>{const b=JSON.stringify({type:"client-request",rpcId:method,method,payload});const r=http.request({host:"127.0.0.1",port:3080,path:"/api/"+method,method:"POST",headers:{"content-type":"application/json","content-length":Buffer.byteLength(b)}},x=>{let s="";x.on("data",d=>s+=d);x.on("end",()=>{let j;try{j=JSON.parse(s)}catch{j={}};res({code:x.statusCode,r:j.result})})});r.on("error",e=>res({code:0,r:{error:{message:e.message}}}));r.end(b)})}
const show=(n,v)=>console.log(n, JSON.stringify(v).slice(0,300));
(async()=>{
  show("skill.list {}", await rpc("skill.list",{}));
  show("credentials.describe {}", await rpc("credentials.describe",{}));
  show("session.search {query}", await rpc("session.search",{query:"a"}));
  show("host.describe {}", await rpc("host.describe",{}));
  show("host.listDirectory {path:/}", await rpc("host.listDirectory",{path:"/"}));
})().catch(e=>console.log("ERR:",e.message));' 2>&1
