let pageHTML = #"""
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Antigravity 自动重试控制台</title>
<link rel="icon" type="image/png" href="\#(faviconDataURI)">
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; background: #0d1117; color: #e6edf3;
         font: 14px/1.6 -apple-system, "PingFang SC", "Helvetica Neue", sans-serif; }
  .wrap { max-width: 960px; margin: 0 auto; padding: 20px 16px 40px; }
  .brand { display: flex; align-items: center; gap: 12px; margin-bottom: 4px; }
  .brand img { width: 40px; height: 40px; border-radius: 9px; flex: none; }
  h1 { font-size: 18px; margin: 0; }
  .sub { color: #8b949e; font-size: 12px; margin-bottom: 16px; }
  .badges { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin: 10px 0 18px; }
  .badge { padding: 3px 12px; border-radius: 999px; font-size: 13px; border: 1px solid #30363d; }
  .ok    { background: #12321f; color: #3fb950; border-color: #1f6f37; }
  .warn  { background: #33230a; color: #d29922; border-color: #9e6a03; }
  .err   { background: #3a1216; color: #f85149; border-color: #b62324; }
  .dim   { background: #161b22; color: #8b949e; }
  button { background: #21262d; color: #e6edf3; border: 1px solid #363b42; border-radius: 6px;
           padding: 6px 14px; font-size: 13px; cursor: pointer; }
  button:hover { background: #30363d; }
  button.primary { background: #1f6feb; border-color: #1f6feb; color: #fff; }
  button.warnb { background: #9e6a03; border-color: #9e6a03; color: #fff; }
  .cards { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  @media (max-width: 720px) { .cards { grid-template-columns: 1fr; } }
  .card { background: #161b22; border: 1px solid #30363d; border-radius: 10px; padding: 14px 16px; }
  .card h2 { font-size: 14px; margin: 0 0 10px; display: flex; justify-content: space-between; align-items: center; }
  .kv { display: flex; justify-content: space-between; font-size: 13px; padding: 2px 0; color: #c9d1d9; }
  .kv span:first-child { color: #8b949e; }
  .panel { background: #161b22; border: 1px solid #30363d; border-radius: 10px; padding: 14px 16px; margin-top: 14px; }
  .panel h2 { font-size: 14px; margin: 0 0 10px; }
  .clicks { margin: 0; padding: 0; list-style: none; max-height: 180px; overflow-y: auto; font-size: 13px; }
  .clicks li { padding: 3px 0; border-bottom: 1px solid #21262d; display: flex; gap: 10px; }
  .clicks time { color: #8b949e; min-width: 70px; }
  #log { background: #0d1117; border: 1px solid #30363d; border-radius: 8px; padding: 10px 12px;
         height: 320px; overflow-y: auto; font: 12px/1.5 "SF Mono", ui-monospace, Menlo, monospace;
         white-space: pre-wrap; word-break: break-all; }
  .lg-click { color: #3fb950; } .lg-err { color: #f85149; } .lg-warn { color: #d29922; } .lg-dim { color: #6e7681; }
  .row { display: flex; gap: 8px; flex-wrap: wrap; }
  .toast { position: fixed; top: 14px; right: 14px; background: #1f6feb; color: #fff; padding: 8px 16px;
           border-radius: 8px; opacity: 0; transition: opacity .3s; pointer-events: none; }
  .toast.show { opacity: 1; }
  .dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; margin-right: 6px; }
  .dot.g { background: #3fb950; box-shadow: 0 0 6px #3fb950; }
  .dot.r { background: #f85149; }
</style>
</head>
<body>
<div class="wrap">
  <div class="brand">
    <img src="\#(faviconDataURI)" alt="Antigravity 自动重试">
    <h1>Antigravity 自动重试控制台</h1>
  </div>
  <div class="sub">守望器每 3 秒扫描一次 agent 面板；10 分钟内最多自动重试 6 次，超过冷却 15 分钟</div>
  <div class="badges" id="badges"></div>
  <div class="row" style="margin-bottom:16px">
    <button id="pauseBtn" onclick="ctrl('pause')">⏸ 暂停自动点击</button>
    <button onclick="ctrl('resume')">▶ 恢复</button>
    <button onclick="ctrl('restart')">🔄 重启守望器</button>
    <button onclick="ctrl('diag')">🔍 运行诊断</button>
    <button onclick="toggleLog()">📜 收起/展开日志</button>
  </div>
  <div class="cards" id="cards"></div>
  <div class="panel">
    <h2>最近自动点击</h2>
    <ul class="clicks" id="clicks"><li class="dim">暂无记录</li></ul>
  </div>
  <div class="panel" id="logPanel">
    <h2>运行日志（实时）</h2>
    <div id="log"></div>
  </div>
  <div class="sub" style="margin-top:14px">
    状态文件: ~/Library/Application Support/AntigravityAutoRetry/ ｜
    服务: launchctl print gui/$UID/com.local.antigravity-retry
  </div>
</div>
<div class="toast" id="toast"></div>
<script>
function esc(s){return (s+'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
function toast(m){const t=document.getElementById('toast');t.textContent=m;t.classList.add('show');setTimeout(()=>t.classList.remove('show'),2200)}
async function ctrl(action){
  try{const r=await fetch('/api/control',{method:'POST',body:JSON.stringify({action})});
      const d=await r.json();toast(d.msg||'已执行');}catch(e){toast('操作失败')}
  poll();
}
let logOpen=true;
function toggleLog(){logOpen=!logOpen;document.getElementById('logPanel').style.display=logOpen?'':'none'}
function fmtTs(iso){try{return new Date(iso).toLocaleTimeString('zh-CN',{hour12:false})}catch(e){return iso}}
function ago(ms){if(ms<3000)return '刚刚';if(ms<60000)return Math.round(ms/1000)+' 秒前';return Math.round(ms/60000)+' 分钟前'}
function classify(line){
  if(/已点击/.test(line))return 'lg-click';
  if(/未授权|异常|失败|已达/.test(line))return 'lg-err';
  if(/暂停|冷却|等待/.test(line))return 'lg-warn';
  if(/心跳|诊断结果|====/.test(line))return 'lg-dim';
  return '';
}
function render(d){
  const b=[];
  if(d.daemon&&d.daemon.alive)b.push('<span class="badge ok"><span class="dot g"></span>守望器运行中 (pid '+d.daemon.pid+')</span>');
  else b.push('<span class="badge err"><span class="dot r"></span>守望器未运行</span>');
  if(d.paused)b.push('<span class="badge warn">已暂停自动点击</span>');
  const st=d.state;
  const cd=st&&st.cooldownUntil?st.cooldownUntil-Date.now():0;
  if(cd>0)b.push('<span class="badge warn">冷却中，剩 '+Math.ceil(cd/1000/60)+' 分钟（restart 可立即恢复）</span>');
  if(st)b.push('<span class="badge dim">数据 '+ago(Date.now()-st.ts)+'</span>');
  document.getElementById('badges').innerHTML=b.join('');
  const pb=document.getElementById('pauseBtn');
  pb.textContent=d.paused?'▶ 恢复自动点击':'⏸ 暂停自动点击';
  pb.onclick=()=>ctrl(d.paused?'resume':'pause');
  pb.className=d.paused?'warnb':'primary';
  const cards=document.getElementById('cards');
  let html='';
  if(st&&st.apps){
    for(const name of Object.keys(st.apps)){
      const a=st.apps[name]||{access:'unknown'};
      let status,cls='dim';
      if(a.access==='ok'){status='<span class="dot g"></span>正常';cls='ok'}
      else if(a.access==='denied'){status='<span class="dot r"></span>未授权';cls='err'}
      else if(a.access==='error'){status='<span class="dot r"></span>出错';cls='err'}
      else if(a.access==='absent'){status='未运行'}
      else status='等待数据';
      html+='<div class="card"><h2>'+esc(name)+'<span class="badge '+cls+'">'+status+'</span></h2>';
      if(a.access==='ok'){
        html+='<div class="kv"><span>窗口</span><span>'+(a.windows!==undefined?a.windows:'-')+'</span></div>';
        html+='<div class="kv"><span>界面节点</span><span>'+(a.nodes||0)+'</span></div>';
        html+='<div class="kv"><span>扫描耗时</span><span>'+(a.ms||'-')+' ms</span></div>';
        html+='<div class="kv"><span>错误卡片</span><span>'+(a.errText?'<span class="badge err">有 — 将自动重试</span>':'无')+'</span></div>';
        if(a.target)html+='<div class="kv"><span>命中按钮</span><span>'+esc(a.target)+'</span></div>';
      } else if(a.detail){html+='<div class="kv"><span>详情</span><span>'+esc(a.detail)+'</span></div>'}
      html+='</div>';
    }
  }
  cards.innerHTML=html||'<div class="card dim">暂无数据（守望器可能未运行）</div>';
  const clicks=(st&&st.clicks)||[];
  const cl=document.getElementById('clicks');
  cl.innerHTML=clicks.length?[...clicks].reverse().map(c=>
    '<li><time>'+fmtTs(c.at)+'</time><span>点击 "'+esc(c.label)+'" ('+esc(c.app)+')</span></li>').join('')
    :'<li class="dim">暂无记录</li>';
  const log=document.getElementById('log');
  const atBottom=log.scrollTop+log.clientHeight>=log.scrollHeight-30;
  log.innerHTML=(d.log||[]).map(l=>{
    const c=classify(l);
    const t=l.replace(/^(\d{4}-\d{2}-\d{2}T(\d{2}:\d{2}:\d{2})[^ ]*)/,(m,_,hm)=>hm);
    return '<div class="'+c+'">'+esc(t)+'</div>';
  }).join('');
  if(atBottom)log.scrollTop=log.scrollHeight;
}
async function poll(){
  try{const r=await fetch('/api/state');render(await r.json())}catch(e){}
}
setInterval(poll,3000);poll();
</script>
</body>
</html>

"""#
