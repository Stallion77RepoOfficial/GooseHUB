from pathlib import Path
import subprocess,json,sys,time,threading,re
r=Path(__file__).resolve().parent;env=json.loads((r/'environment.json').read_text());game=Path(env['WINEPREFIX'])/'drive_c/Program Files (x86)/cs16v2017_oyunyoneticisi'
label=sys.argv[1];extra=sys.argv[2:]
qconsole=game/'qconsole.log';qconsole.unlink(missing_ok=True)
args=['-game','cstrike','-windowed','-w','960','-h','600','-nojoy','-noipx','+exec','codex_probe.cfg',*extra]
logpath=r/(label+'.log');start=time.monotonic()
with logpath.open('w') as log:
 p=subprocess.Popen([str(Path(env['WINESERVER']).parent/'wine'),str(game/'hl.exe'),*args],cwd=game,env=env,stdout=log,stderr=subprocess.STDOUT)
 print('started',label,p.pid,flush=True)
 (r/'active-game.pid').write_text(str(p.pid))
 try:
  deadline=time.monotonic()+100
  observed=False
  while p.poll() is None and time.monotonic()<deadline:
   if qconsole.exists():
    current=qconsole.read_text(errors='replace')
    if re.search(r"\d+ frames .*?seconds .*?(fps|fps\.)",current,re.I):
     observed=True;break
   time.sleep(0.05)
  if observed:
   subprocess.run([env['WINESERVER'],'-k'],env=env,capture_output=True,timeout=10)
   code=p.wait(timeout=10);timedout=False
  else:code=p.wait(timeout=max(1,deadline-time.monotonic()));timedout=False
 except subprocess.TimeoutExpired:
  subprocess.run([env['WINESERVER'],'-k'],env=env,capture_output=True,timeout=10);code=p.wait(timeout=10);timedout=True
 finally:subprocess.run([env['WINESERVER'],'-k'],env=env,capture_output=True,timeout=10)
text=logpath.read_text(errors='replace');console=qconsole.read_text(errors='replace') if qconsole.exists() else ''
(r/(label+'-console.log')).write_text(console)
result={'label':label,'seconds':time.monotonic()-start,'exitCode':code,'timedOut':timedout,'arguments':args,'timerefresh':[line for line in console.splitlines() if re.search(r'\d.*\b(fps|seconds)\b',line,re.I)],'markers':[line for line in console.splitlines() if 'CODEX_' in line],'dxmtFrameReports':[line for line in text.splitlines() if 'draws/frame' in line],'graphicsModules':[line for line in text.splitlines() if 'Loaded ' in line and any(name in line.lower() for name in ['ddraw.dll','d3d8.dll','d3d9.dll','opengl32.dll','wined3d.dll'])]}
(r/(label+'.json')).write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2),flush=True)
