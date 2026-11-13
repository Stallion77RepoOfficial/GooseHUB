from pathlib import Path
import json,subprocess,time,re,os,sys,shutil,ctypes
r=Path(__file__).resolve().parent;label=sys.argv[1];e=json.loads((r/os.environ.get('GOOSE_SCENE_ENV_FILE','environment.probe.json')).read_text());g=Path(e['WINEPREFIX'])/'drive_c/Program Files (x86)/cs16v2017_oyunyoneticisi';q=g/'qconsole.log';q.unlink(missing_ok=True)
if os.environ.get('GOOSE_DISABLE_INLINE')=='1':e['GOOSE_GL_INLINE']='0'
e['GOOSE_FRAME_LOG']=str(r/(label+'-frames.csv'));e['WINEDEBUG']='err+all,fixme-all';e['MTL_HUD_ENABLED']='0';shutil.copy2(r/'cs-characters-record.dem',g/'cstrike/load_characters.dem')
clock=ctypes.CDLL('/usr/lib/libSystem.B.dylib');clock.mach_absolute_time.restype=ctypes.c_uint64
class Timebase(ctypes.Structure):_fields_=[('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]
tb=Timebase();clock.mach_timebase_info(ctypes.byref(tb))
args=[str(g/'hl.exe'),'-game','cstrike','-windowed','-w','960','-h','600','-gl','-32bpp','-nojoy','-noipx','+condebug','+developer','1','+fps_max','999','+timedemo','load_characters'];start=time.monotonic();native=None
with (r/(label+'.log')).open('w') as log:
 p=subprocess.Popen([str(Path(e['WINESERVER']).parent/'wine'),*args],cwd=g,env=e,stdout=log,stderr=subprocess.STDOUT);print('START',label,p.pid,flush=True)
 try:
  while p.poll() is None and time.monotonic()-start<90:
   text=q.read_text(errors='replace') if q.exists() else '';m=re.search(r'(\d+) frames ([\d.]+) seconds ([\d.]+) fps',text)
   if m:native={'frames':int(m[1]),'seconds':float(m[2]),'fps':float(m[3])};print('TIMEDEMO',native,flush=True);break
   time.sleep(.1)
 finally:
  subprocess.run([e['WINESERVER'],'-k'],env=e,capture_output=True,timeout=10);code=p.wait(timeout=10)
(r/(label+'.json')).write_text(json.dumps({'label':label,'nativeTimedemo':native,'inline':e.get('GOOSE_GL_INLINE','0'),'timebase':{'numer':tb.numer,'denom':tb.denom},'elapsed':time.monotonic()-start,'returnCode':code,'arguments':args},indent=2)+'\n')
if q.exists():shutil.copy2(q,r/(label+'-console.log'))
