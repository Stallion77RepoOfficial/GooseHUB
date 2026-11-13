from pathlib import Path
import subprocess,json,time,socket,re,secrets,sys,ctypes,os
r=Path(__file__).resolve().parent;e=json.loads((r/os.environ.get('GOOSE_SCENE_ENV_FILE','environment.probe.json')).read_text());label=sys.argv[1] if len(sys.argv)>1 else 'cs-load-01'
prefix=Path(e['WINEPREFIX']);g=prefix/'drive_c/Program Files (x86)/cs16v2017_oyunyoneticisi';e['GOOSE_FRAME_LOG']=str(r/(label+'-frames.csv'));e['WINEDEBUG']='err+all,fixme-all,+loaddll';port=27615;password=secrets.token_hex(10)
clock=ctypes.CDLL('/usr/lib/libSystem.B.dylib');clock.mach_absolute_time.restype=ctypes.c_uint64
class Timebase(ctypes.Structure):_fields_=[('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]
tb=Timebase();clock.mach_timebase_info(ctypes.byref(tb))
q=g/'qconsole.log';q.unlink(missing_ok=True)
args=[str(g/'hl.exe'),'-game','cstrike','-windowed','-w','960','-h','600','-nojoy','-noipx','-ip','127.0.0.1','-port',str(port),'-gl','-32bpp','+condebug','+maxplayers','20','+sv_lan','1','+rcon_password',password,'+developer','1','+fps_max','999','+sv_cheats','1','+map','de_dust2']
sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);sock.settimeout(.35);target=('127.0.0.1',port);events=[];phases=[];start=time.monotonic()
def query(message):
 sock.sendto(b'\xff\xff\xff\xff'+message.encode()+b'\n',target);parts=[]
 while True:
  try:parts.append(sock.recv(65536).decode('latin1',errors='replace'))
  except socket.timeout:break
 return ''.join(parts)
challenge_token=None
def command(cmd):
 global challenge_token
 for attempt in range(8):
  if challenge_token is None:
   challenge=query('challenge rcon');match=re.search(r'challenge rcon ([-\d]+)',challenge)
   if not match:continue
   challenge_token=match[1]
  response=query('rcon '+challenge_token+' "'+password+'" '+cmd)
  if 'Bad challenge' in response:challenge_token=None;continue
  if response:
   events.append({'elapsed':time.monotonic()-start,'command':cmd,'response':response});return response
 raise RuntimeError('RCON did not acknowledge '+cmd)

with (r/(label+'.log')).open('w') as log:
 p=subprocess.Popen([str(Path(e['WINESERVER']).parent/'wine'),*args],cwd=g,env=e,stdout=log,stderr=subprocess.STDOUT);print('START',p.pid,flush=True)
 try:
  active=False
  while p.poll() is None and time.monotonic()-start<45:
   try:reply=command('status')
   except RuntimeError:
    time.sleep(.5);continue
   m=re.search(r'players\s*:\s*(\d+) active',reply)
   if m and int(m[1])>0 and re.search(r'#\s+1\s+',reply):active=True;break
   time.sleep(.5)
  assert active,'Local player did not connect'
  for cmd in ['bench_join','developer 1','fps_max 999','sv_cheats 1','mp_limitteams 0','mp_autoteambalance 0','mp_freezetime 0','mp_roundtime 9','bot_join_after_player 0','bot_auto_vacate 0','bot_quota 0','bot_stop 1','bot_zombie 1','bot_allow_grenades 0','amxx plugins']:
   reply=command(cmd)
   if cmd=='amxx plugins':print('PLUGIN',reply.replace('\n',' / '),flush=True)
  print('JOIN',command('bench_join').replace('\n',' / '),flush=True)
  command('bot_quota 15')
  bot_deadline=time.monotonic()+40
  while time.monotonic()<bot_deadline:
   try:status=command('status')
   except RuntimeError:
    time.sleep(.5);continue
   if re.search(r'players\s*:\s*16 active',status):break
   time.sleep(.5)
  print('STATUS',status.replace('\n',' / '),flush=True);assert re.search(r'players\s*:\s*16 active',status),'Expected 16 active players'
  command('sv_restart 1');time.sleep(4)
  print('SPAWN',command('bench_report').replace('\n',' / '),flush=True)
  print('FORM',command('bench_form').replace('\n',' / '),flush=True)
  report=command('bench_report');print('REPORT',report.replace('\n',' / '),flush=True);assert 'human_alive=1 alive=16' in report and 'peers_visible=15' in report,'All sixteen players must be alive before measurement'
  if os.environ.get('GOOSE_RECORD_SCENE')=='1':command('record fps_load_scene')
  plan=[('hidden-16-frozen',['bench_visible 0','bench_effects 0','r_drawentities 1']),('visible-15-frozen',['bench_visible 15']),('hidden-16-repeat',['bench_visible 0']),('visible-15-smoke',['bench_visible 15','bench_effects 1']),('visible-15-light',['bench_effects 2']),('visible-15-smoke-light',['bench_visible 15','bench_effects 3']),('visible-15-clean-repeat',['bench_effects 0']),('entities-disabled',['r_drawentities 0']),('visible-15-pan',['r_drawentities 1','cl_yawspeed 60','+right'])]
  if os.environ.get('GOOSE_SHORT_SCENE')=='1':plan=[plan[0],plan[1],plan[2],plan[5],plan[6]]
  if os.environ.get('GOOSE_MODELS_ONLY')=='1':plan=plan[:3]
  if os.environ.get('GOOSE_RECORD_ONLY')=='1':plan=[plan[1]]
  for name,cmds in plan:
   for cmd in cmds:command(cmd)
   time.sleep(2)
   command('fps_max');command('developer');report=command('bench_report');assert 'offgrid=0' in report and 'yaw=180.00' in report and 'human_alive=1 alive=16 ct=8 t=8' in report,'Scene player state changed: '+report
   begin=clock.mach_absolute_time();print('PHASE',name,'BEGIN',round(time.monotonic()-start,2),flush=True)
   sampler=None
   if os.environ.get('GOOSE_PROFILE')=='1' and name=='visible-15-frozen':
    sampler=subprocess.Popen(['/usr/bin/sample',str(p.pid),'5','2','-file',str(r/(label+'.sample.txt'))],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   time.sleep(7)
   if sampler:sampler.wait(timeout=10)
   end=clock.mach_absolute_time();phases.append({'name':name,'beginTicks':begin,'endTicks':end,'report':report,'commands':cmds});print('PHASE',name,'END',round(time.monotonic()-start,2),flush=True)
  command('-right');command('stop');command('quit')
  try:code=p.wait(timeout=10)
  except subprocess.TimeoutExpired:subprocess.run([e['WINESERVER'],'-k'],env=e,capture_output=True,timeout=10);code=p.wait(timeout=10)
 finally:
  subprocess.run([e['WINESERVER'],'-k'],env=e,capture_output=True,timeout=10)
  result={'label':label,'activePlayer':active,'timebase':{'numer':tb.numer,'denom':tb.denom},'phases':phases,'events':events,'arguments':args,'elapsed':time.monotonic()-start,'returnCode':p.poll(),'demoRecorded':os.environ.get('GOOSE_RECORD_SCENE')=='1','profiled':os.environ.get('GOOSE_PROFILE')=='1'};(r/(label+'.json')).write_text(json.dumps(result,indent=2)+'\n')
  if q.exists():(r/(label+'-console.log')).write_text(q.read_text(errors='replace'))
  demo=g/'cstrike/fps_load_scene.dem'
  if demo.exists():subprocess.run(['/bin/cp','-c',str(demo),str(r/(label+'.dem'))],check=True)
print('DONE',len(phases),flush=True)
