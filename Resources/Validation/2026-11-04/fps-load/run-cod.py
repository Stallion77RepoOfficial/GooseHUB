from pathlib import Path
import json,re,subprocess,sys,threading,time
r=Path(__file__).resolve().parent;g=r/'CoD-game';label=sys.argv[1];duration=int(sys.argv[2]) if len(sys.argv)>2 else 60
e=json.loads((r/'environment.json').read_text());old=str(r.parents[1]/'Engines');new=str(r/'FinalEngines');e={k:v.replace(old,new) for k,v in e.items()};e['FEX_X87REDUCEDPRECISION']='1';e['DXMT_FPS']='1';e['MTL_HUD_ENABLED']='0';e['DXMT_CONFIG']='d3d11.asyncPipelineCompilation=False';e['WINEDEBUG']='err+all,fixme-all';e['DXMT_LOG_LEVEL']='info'
# Keep the owned test profile aligned with the last detected hardware. A changed
# emulated CPU benchmark can otherwise open the game's recommendation dialog.
config=g/'players/profiles/Default/config.cfg'
previous=g/'main/console.log'
found=re.findall(r'dvar set sys_configureGHz ([0-9.]+)',previous.read_text(errors='replace')) if previous.exists() else []
if config.exists() and found:
 text=config.read_text();text=re.sub(r'seta sys_configSum "[^"]*"','seta sys_configSum "0"',text)
 text=re.sub(r'seta sys_configureGHz "[^"]*"','seta sys_configureGHz "'+found[-1]+'"',text);config.write_text(text)
(g/'__iw3sp').unlink(missing_ok=True)
args=['+set','com_recommendedSet','1','+set','com_introPlayed','1','+set','r_fullscreen','0','+set','r_mode','1280x720','+set','r_vsync','0','+set','com_maxfps','0','+set','logfile','2','+set','developer','1','+set','sv_cheats','1','+devmap','bog_a']
start=time.monotonic();groups=[];p=None
with (r/(label+'.log')).open('w',buffering=1) as log:
 p=subprocess.Popen([str(Path(e['WINESERVER']).parent/'wine'),str(g/'iw3sp.exe'),*args],env=e,cwd=g,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 def collect():
  for raw in iter(p.stdout.readline,b''):
   line=raw.decode(errors='replace');elapsed=time.monotonic()-start;log.write(f'{elapsed:.3f} {line}')
   m=re.search(r'fps ([\d.]+) over 60 frames, draws/frame (\d+).*?prepare ([\d.]+) ms/frame, upload ([\d.]+) ms/frame, bind ([\d.]+) ms/frame',line)
   if m:groups.append(dict(elapsed=elapsed,fps=float(m[1]),draws=int(m[2]),prepareMs=float(m[3]),uploadMs=float(m[4]),bindMs=float(m[5])))
 thread=threading.Thread(target=collect,daemon=True);thread.start();print('START',label,p.pid,flush=True)
 try:p.wait(timeout=duration)
 except subprocess.TimeoutExpired:subprocess.run([e['WINESERVER'],'-k'],env=e,capture_output=True,timeout=10);p.wait(timeout=10)
 thread.join(timeout=5)
(r/(label+'.json')).write_text(json.dumps(dict(label=label,elapsed=time.monotonic()-start,groups=groups,exitAfterTestStop=p.returncode,arguments=args),indent=2)+'\n')
print('RESULT',label,'groups',len(groups),'dense',len([x for x in groups if x['draws']>=1000]),'last',groups[-1:] if groups else [],flush=True)
