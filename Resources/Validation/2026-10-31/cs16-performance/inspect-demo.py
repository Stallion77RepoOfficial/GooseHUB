from pathlib import Path
import json,struct,sys,collections
p=Path(sys.argv[1]);b=p.read_bytes();assert b[:8]==b'HLDEMO\0\0';directory=struct.unpack_from('<i',b,540)[0];n=struct.unpack_from('<i',b,directory)[0];result=[]
for i in range(n):
 row=struct.unpack_from('<i64siifiii',b,directory+4+92*i);kind,name,flags,cd,seconds,frames,offset,length=row;pos=offset;end=offset+length;types=collections.Counter();samples=[];commands=[]
 while pos<end:
  f,t,index=struct.unpack_from('<Bfi',b,pos);pos+=9;types[f]+=1
  if f in [0,1]:
   size=struct.unpack_from('<i',b,pos+464)[0];assert 0<=size<=65536,(pos,size)
   rp=pos+4;samples.append({'time':t,'origin':struct.unpack_from('<3f',b,rp),'angles':struct.unpack_from('<3f',b,rp+12),'health':struct.unpack_from('<i',b,rp+140)[0],'onlyClientDraw':struct.unpack_from('<i',b,rp+228)[0]});pos+=468+size
  elif f in [2,5]:pass
  elif f==3:commands.append(b[pos:pos+64].split(b'\0')[0].decode(errors='replace'));pos+=64
  elif f==4:pos+=32
  elif f==6:pos+=84
  elif f==7:pos+=8
  elif f==8:size=struct.unpack_from('<i',b,pos+4)[0];pos+=24+size
  elif f==9:size=struct.unpack_from('<i',b,pos)[0];pos+=4+size
  else:raise ValueError((pos,f))
  if f==5:break
 ranges={key:[[min(v[key][j] for v in samples),max(v[key][j] for v in samples)] for j in range(3)] for key in ['origin','angles']} if samples else {}
 result.append({'description':name.split(b'\0')[0].decode(),'seconds':seconds,'directoryFrames':frames,'typeCounts':dict(types),'sampleCount':len(samples),'ranges':ranges,'healthRange':[min(v['health'] for v in samples),max(v['health'] for v in samples)] if samples else None,'onlyClientDraw':sorted(set(v['onlyClientDraw'] for v in samples)),'commands':commands,'bytesParsed':pos-offset,'entryLength':length})
print(json.dumps(result,indent=2))
