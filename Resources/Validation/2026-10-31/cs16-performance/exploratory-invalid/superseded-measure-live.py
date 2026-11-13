from pathlib import Path
import subprocess,json,sys,time,re,threading
r=Path(__file__).resolve().parent;label=sys.argv[1];mode=int(sys.argv[2]);bpp=int(sys.argv[3]);hud=sys.argv[4]=='on';native=sys.argv[5]=='dxmt';fps=int(sys.argv[6]) if len(sys.argv)>6 else 100;extra=sys.argv[7:]
env=json.loads((r/'environment.json').read_text());env['WINEDEBUG']='err+all,fixme-all,+loaddll';env['MTL_HUD_ENABLED']='1' if hud else '0'
env['WINEDLLOVERRIDES']='d3d8,d3d9,d3d10core,d3d11,d3d12,dxgi='+('n,b' if native else 'b')+';winemetal=b'
prefix=Path(env['WINEPREFIX']);game=prefix/'drive_c/Program Files (x86)/cs16v2017_oyunyoneticisi';reg=prefix/'user.reg'
text=reg.read_text();parts=re.split(r'(?=^\[)',text,flags=re.M)
for i,section in enumerate(parts):
 if section.startswith('[Software\\\\Valve\\\\Half-Life\\\\Settings]'):
  section=re.sub(r'"EngineD3D"=dword:[0-9a-f]+',f'"EngineD3D"=dword:{mode:08x}',section)
  section=re.sub(r'"ScreenBPP"=dword:[0-9a-f]+',f'"ScreenBPP"=dword:{bpp:08x}',section)
  parts[i]=section
reg.write_text(''.join(parts))
qconsole=game/'qconsole.log';qconsole.unlink(missing_ok=True)
# Preserve the user's 100 FPS setting for a live comparison. Timerefresh is separate.
frames=1800 if fps>100 else 900
cfg='condebug\necho CODEX_START\nmap de_dust2\n'+'wait\n'*150+f'developer {1 if fps>100 else 0}\nfps_max {fps}\nfps_modem 0\necho CODEX_FRAMES_BEGIN\n'+'wait\n'*frames+'echo CODEX_FRAMES_END\nfps_max\ngl_vsync\ndeveloper\ntimerefresh\necho CODEX_DONE\nquit\n'
(game/'cstrike/codex_probe.cfg').write_text(cfg)
args=['-game','cstrike','-windowed','-w','960','-h','600','-nojoy','-noipx',*extra,'+exec','codex_probe.cfg']
nativeStart=time.clock_gettime(time.CLOCK_MONOTONIC);start=time.monotonic();marks={};sampled=True;sample_proc=None
with (r/(label+'.log')).open('w') as log:
 p=subprocess.Popen([str(Path(env['WINESERVER']).parent/'wine'),str(game/'hl.exe'),*args],env=env,cwd=game,stdout=log,stderr=subprocess.STDOUT)
 print('START',label,'pid',p.pid,flush=True)
 while p.poll() is None and time.monotonic()-start<100:
  if qconsole.exists():
   console=qconsole.read_text(errors='replace')
   for marker in ['CODEX_START','CODEX_FRAMES_BEGIN','CODEX_FRAMES_END','CODEX_DONE']:
    if marker not in marks and marker in console:
     marks[marker]=time.monotonic()-start
     print(label,marker,round(marks[marker],3),flush=True)
   if 'CODEX_FRAMES_BEGIN' in marks and not sampled:
    sampled=True
    sample_proc=subprocess.Popen(['/usr/bin/sample',str(p.pid),'3','1','-file',str(r/(label+'.sample.txt'))],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  time.sleep(0.025)
 timeout=p.poll() is None
 if timeout:subprocess.run([env['WINESERVER'],'-k'],env=env,capture_output=True,timeout=10)
 code=p.wait(timeout=10)
 subprocess.run([env['WINESERVER'],'-k'],env=env,capture_output=True,timeout=10)
 if sample_proc:sample_proc.wait(timeout=10)
console=qconsole.read_text(errors='replace') if qconsole.exists() else '';logtext=(r/(label+'.log')).read_text(errors='replace')
(r/(label+'-console.log')).write_text(console)
duration=marks.get('CODEX_FRAMES_END',0)-marks.get('CODEX_FRAMES_BEGIN',0)
result={'hostMonotonicStart':start,'nativeMonotonicStart':nativeStart,'arguments':args,'presentationSamples':[dict(zip(['kind','monotonicEnd','seconds','count','fps','meanMilliseconds','maximumMilliseconds','flags'],m)) for m in re.findall(r'GOOSE_PRESENT kind=(\w+) now=([\d.]+) seconds=([\d.]+) count=(\d+) fps=([\d.]+) mean_ms=([\d.]+) max_ms=([\d.]+) flags=(0x[\da-f]+|0)',logtext)],'label':label,'mode':mode,'bitsPerPixel':bpp,'requestedFPS':fps,'metalHUD':hud,'bottleBackend':'dxmt' if native else 'wined3d','seconds':time.monotonic()-start,'exitCode':code,'timeout':timeout,'markers':marks,'waitFrames':frames,'liveFramesPerSecond':frames/duration if duration>0 else None,'timerefresh':[x for x in console.splitlines() if re.search(r'\d.*seconds.*fps',x,re.I)],'graphicsModules':[x for x in logtext.splitlines() if 'Loaded ' in x and any(n in x.lower() for n in ['ddraw.dll','d3d8.dll','d3d9.dll','d3d11.dll','winemetal.dll','opengl32.dll','wined3d.dll'])]}
(r/(label+'.json')).write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2),flush=True)
