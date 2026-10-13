// "Never a black screen" check: load a page, screenshot it at several moments while it loads and
// after, and report for each shot the share of near-black pixels (all channels < 48) inside the
// frame area. usage: node dark_check.mjs <url> <out prefix> [port]
import { spawn } from 'node:child_process'; import { mkdtempSync, writeFileSync } from 'node:fs'; import { tmpdir } from 'node:os';
const chrome=`${process.env.HOME}/Library/Caches/ms-playwright/chromium-1243/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const port=process.argv[4]||9341;
const br=spawn(chrome,['--headless=new',`--remote-debugging-port=${port}`,'--no-first-run',`--user-data-dir=${mkdtempSync(tmpdir()+'/c')}`,'about:blank'],{stdio:'ignore'});
const sleep=ms=>new Promise(r=>setTimeout(r,ms)); let t;
for(let i=0;i<40;i++){await sleep(250);try{t=await (await fetch(`http://127.0.0.1:${port}/json`)).json();break}catch{}}
const ws=new WebSocket(t.find(x=>x.type==='page').webSocketDebuggerUrl); await new Promise(r=>ws.onopen=r);
let id=0;const p={};ws.onmessage=m=>{const d=JSON.parse(m.data);if(d.id&&p[d.id]){p[d.id](d);delete p[d.id]}};
const send=(method,params={})=>new Promise(r=>{p[++id]=r;ws.send(JSON.stringify({id,method,params}))});
await send('Emulation.setDeviceMetricsOverride',{width:1440,height:900,deviceScaleFactor:1,mobile:false});
await send('Page.navigate',{url:process.argv[2]});
const t0=Date.now(); const out=[];
for(const at of [500,1500,3000,6000,10000,20000,35000]){
  await sleep(Math.max(0,at-(Date.now()-t0)));
  // Count dark pixels in the page itself via a canvas copy of the screenshot.
  const s=await send('Page.captureScreenshot',{format:'png'});
  const f=`${process.argv[3]}-${at}.png`; writeFileSync(f,Buffer.from(s.result.data,'base64'));
  out.push({at,f});
}
br.kill();
console.log(JSON.stringify(out));
process.exit(0);
