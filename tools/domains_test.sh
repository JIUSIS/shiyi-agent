#!/system/bin/sh
# verify all new DSH API domains against live service
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
if ! node -e 'require("http").get("http://127.0.0.1:3080/",r=>process.exit(0)).on("error",()=>process.exit(1))' 2>/dev/null; then
  nohup "$U/bin/node" --expose-internals "$U/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" web > "$P/tmp/domains.log" 2>&1 &
  sleep 13
fi
node -e '
const http=require("http");
function rpc(method,payload){return new Promise((res)=>{const b=JSON.stringify({type:"client-request",rpcId:method,method,payload});const r=http.request({host:"127.0.0.1",port:3080,path:"/api/"+method,method:"POST",headers:{"content-type":"application/json","content-length":Buffer.byteLength(b)}},x=>{let s="";x.on("data",d=>s+=d);x.on("end",()=>{let j;try{j=JSON.parse(s)}catch{j={}};res({code:x.statusCode,r:j.result})})});r.on("error",e=>res({code:0,r:{error:{message:e.message}}}));r.end(b)})}
const show=(n,v)=>console.log(n, JSON.stringify(v).slice(0,220));
(async()=>{
  const c=await rpc("session.create",{});
  const sid=c.r.value?.sessionId;
  show("session.create",c.r);
  // models
  const m=await rpc("session.models",{sessionId:sid});
  show("session.models",{ok:m.r.ok, current:m.r.value?.current, groups:(m.r.value?.groups||[]).length});
  const l=await rpc("llm.models",{});
  show("llm.models",{ok:l.r.ok, groups:(l.r.value?.groups||[]).length});
  const pv=await rpc("llm.providers",{});
  show("llm.providers",{ok:pv.r.ok, n:(pv.r.value?.providers||[]).length});
  // presets
  const pr=await rpc("agentPreset.list",{});
  show("agentPreset.list",{ok:pr.r.ok, presets:(pr.r.value?.presets||[]).map(p=>p.id)});
  const rd=await rpc("agentPreset.read",{agentPreset:"android"});
  show("agentPreset.read",{ok:rd.r.ok, trust:rd.r.value?.trust, len:(rd.r.value?.content||"").length});
  // workspace
  const ws=await rpc("workspace.list",{});
  show("workspace.list",{ok:ws.r.ok, items:(ws.r.value?.items||[]).length});
  // skills
  const sk=await rpc("skill.list",{});
  show("skill.list",{ok:sk.r.ok, keys:Object.keys(sk.r.value||{})});
  // credentials
  const cr=await rpc("credentials.describe",{});
  show("credentials.describe",{ok:cr.r.ok, keys:Object.keys(cr.r.value||{})});
  // host
  const h=await rpc("host.describe",{});
  show("host.describe",{ok:h.r.ok, platform:h.r.value?.platform, cwd:h.r.value?.cwd});
  // settings
  const st=await rpc("settings.describe",{});
  show("settings.describe",{ok:st.r.ok, nss:(st.r.value?.namespaces||[]).map(n=>n.ns)});
  // subagent list
  const sa=await rpc("subagent.list",{parentSessionId:sid});
  show("subagent.list",{ok:sa.r.ok, entries:(sa.r.value?.entries||[]).length});
  // search
  const se=await rpc("session.search",{query:"test"});
  show("session.search",{ok:se.r.ok});
  // goal
  const g=await rpc("goal.create",{sessionId:sid,objective:"test goal"});
  show("goal.create",{ok:g.r.ok, ref:g.r.value?.goalId});
  if(g.r.value?.goalId){const gc=await rpc("goal.clear",{sessionId:sid,ref:g.r.value.goalId});show("goal.clear",{ok:gc.r.ok})}
})().catch(e=>console.log("ERR:",e.message));' 2>&1
