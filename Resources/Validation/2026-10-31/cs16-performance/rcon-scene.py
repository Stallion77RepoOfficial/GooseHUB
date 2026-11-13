from pathlib import Path
import subprocess,json,time,socket,re,secrets,sys
r=Path(__file__).resolve().parent;e=json.loads((r/'environment.json').read_text());label=sys.argv[1];backend=sys.argv[2] if len(sys.argv)>2 else 'dxmt'
e['WINEDEBUG']='err+all,fixme-all,+loaddll';e['MTL_HUD_ENABLED']='0'
e['WINEDLLOVERRIDES']='d3d8,d3d9,d3d10core,d3d11,d3d12,dxgi='+('n,b' if backend=='dxmt' else 'b')+';winemetal=b'+(';'+'ddraw=n,b' if backend=='dxmt' else '')
prefix=Path(e['WINEPREFIX']);g=prefix/'drive_c/Program Files (x86)/cs16v2017_oyunyoneticisi'
listen=g/'cstrike/listenserver.cfg';text=listen.read_text(errors='replace');text=re.sub(r'(?m)^sv_lan\s+\d+', 'sv_lan 1',text);listen.write_text(text)
password=secrets.token_hex(10);port=27615
q=g/'qconsole.log';q.unlink(missing_ok=True)
args=[str(g/'hl.exe'),'-game','cstrike','-windowed','-w','960','-h','600','-nojoy','-noipx','-ip','127.0.0.1','-port',str(port),'-d3d' if backend=='dxmt' else '-gl','-32bpp','+condebug','+maxplayers','8','+sv_lan','1','+rcon_password',password,'+developer','1','+fps_max','999','+map','de_dust2']
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(.3);target=('127.0.0.1',port);events=[]
def query(message):
 s.sendto(b'\xff\xff\xff\xff'+message.encode()+b'\n',target);parts=[]
 while True:
  try:parts.append(s.recv(65536).decode('latin1',errors='replace'))
  except socket.timeout:break
 return ''.join(parts)
def command(cmd):
 challenge=query('challenge rcon');m=re.search(r'challenge rcon ([-\d]+)',challenge)
 if not m:return None
 reply=query('rcon '+m.group(1)+' "'+password+'" '+cmd)
 events.append({'time':time.monotonic()-start,'command':cmd,'response':reply});return reply
start=time.monotonic()
with (r/(label+'.log')).open('w') as log:
 p=subprocess.Popen([str(Path(e['WINESERVER']).parent/'wine'),*args],env=e,cwd=g,stdout=log,stderr=subprocess.STDOUT);print('START',label,p.pid,flush=True)
 try:
  active=False;status=''
  while p.poll() is None and time.monotonic()-start<45:
   reply=command('status')
   if reply:
    status=reply
    print('STATUS',round(time.monotonic()-start,2),reply[-160:].replace('\n',' / '),flush=True)
    m=re.search(r'players\s*:\s*(\d+) active',reply)
    if m and int(m.group(1))>0:active=True;break
   time.sleep(1)
  print('ACTIVE_PLAYER',active,flush=True)
  if active:
   for cmd in ['jointeam 2','joinclass 1','developer 1','fps_max 999','sv_cheats 1','noclip','cl_yawspeed 60','record codex_moving']:
    print('COMMAND',cmd,repr(command(cmd))[:350],flush=True)
   time.sleep(3)
   print('SCENE_MEASURE_BEGIN',round(time.monotonic()-start,3),flush=True)
   command('+right');command('+forward')
   time.sleep(12)
   command('-forward');command('-right');command('stop');command('status')
   print('SCENE_MEASURE_END',round(time.monotonic()-start,3),flush=True)
  else:
   print('CONSOLE',q.read_text(errors='replace')[-3000:] if q.exists() else 'absent',flush=True)
  command('quit')
  try:code=p.wait(timeout=12)
  except subprocess.TimeoutExpired:subprocess.run([e['WINESERVER'],'-k'],env=e,capture_output=True,timeout=10);code=p.wait(timeout=10)
 finally:subprocess.run([e['WINESERVER'],'-k'],env=e,capture_output=True,timeout=10)
(r/(label+'-rcon.json')).write_text(json.dumps({'activePlayer':active,'exitCode':code,'seconds':time.monotonic()-start,'events':events},indent=2)+'\n')
if q.exists():(r/(label+'-console.log')).write_text(q.read_text(errors='replace'))
