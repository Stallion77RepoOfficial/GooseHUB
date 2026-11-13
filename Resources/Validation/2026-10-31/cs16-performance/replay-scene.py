from pathlib import Path
import json,sys,subprocess,time,re,os
r=Path(__file__).resolve().parent;e=json.loads((r/os.environ.get('GOOSE_SCENE_ENV_FILE','environment.json')).read_text());label=sys.argv[1];backend=sys.argv[2];hud=sys.argv[3]=='on' if len(sys.argv)>3 else False
prefix=Path(e['WINEPREFIX']);g=prefix/'drive_c/Program Files (x86)/cs16v2017_oyunyoneticisi';q=g/'qconsole.log';q.unlink(missing_ok=True)
e['WINEDEBUG']='err+all,fixme-all,+loaddll';e['MTL_HUD_ENABLED']='1' if hud else '0'
e['WINEDLLOVERRIDES']='d3d8,d3d9,d3d10core,d3d11,d3d12,dxgi='+('n,b' if backend=='dxmt' else 'b')+';winemetal=b;ddraw='+('n,b' if backend=='dxmt' else 'b')+';opengl32='+('n' if backend=='wmgl' else 'b')+(';winemetalgl=n,b' if backend=='wmgl' else '')
reg=prefix/'user.reg';s=reg.read_text();s=s.replace('"AllowVerticalSync"="Y"','"AllowVerticalSync"="N"');reg.write_text(s)
args=[str(g/'hl.exe'),'-game','cstrike','-windowed','-w','960','-h','600','-nojoy','-noipx','-gl' if backend in ['gl','wmgl'] else '-d3d','-32bpp','+condebug','+developer','1','+fps_max','999','+timedemo','codex_moving']
start=time.monotonic();native=None;sample=None;client_loaded=None
with (r/(label+'.log')).open('w') as log:
 p=subprocess.Popen([str(Path(e['WINESERVER']).parent/'wine'),*args],env=e,cwd=g,stdout=log,stderr=subprocess.STDOUT);print('START',label,p.pid,flush=True)
 while p.poll() is None and time.monotonic()-start<90:
  console=q.read_text(errors='replace') if q.exists() else ''
  if e.get('GOOSE_SCENE_SAMPLE')=='1' and sample is None:
   current=(r/(label+'.log')).read_text(errors='replace')
   if 'client.dll' in current and client_loaded is None:client_loaded=time.monotonic()
   if client_loaded and time.monotonic()-client_loaded>2:
    sample=subprocess.Popen(['/usr/bin/sample',str(p.pid),'5','2','-file',str(r/(label+'.sample.txt'))],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    print('CPU_SAMPLE_STARTED',round(time.monotonic()-start,3),flush=True)
  m=re.search(r'(\d+) frames ([\d.]+) seconds ([\d.]+) fps',console)
  if m:native={'frames':int(m[1]),'seconds':float(m[2]),'fps':float(m[3])};print('NATIVE_TIMEDEMO',json.dumps(native),flush=True);break
  time.sleep(.1)
 if p.poll() is None:subprocess.run([e['WINESERVER'],'-k'],env=e,capture_output=True,timeout=10)
 code=p.wait(timeout=10);subprocess.run([e['WINESERVER'],'-k'],env=e,capture_output=True,timeout=10)
if sample:sample.wait(timeout=10)
console=q.read_text(errors='replace') if q.exists() else '';raw=(r/(label+'.log')).read_text(errors='replace');(r/(label+'-console.log')).write_text(console)
d={'x87ReducedPrecision':e.get('FEX_X87REDUCEDPRECISION'),'label':label,'backend':backend,'nativeTimedemo':native,'metalHUD':hud,'seconds':time.monotonic()-start,'exitCode':code,'controlledStopAfterResult':native is not None,'arguments':args,'graphicsModules':[l for l in raw.splitlines() if 'Loaded ' in l and any(d in l.lower() for d in ['ddraw.dll','d3d9.dll','d3d11.dll','winemetal.dll','opengl32.dll','wined3d.dll'])]};(r/(label+'.json')).write_text(json.dumps(d,indent=2)+'\n');print(json.dumps(d,indent=2),flush=True)
