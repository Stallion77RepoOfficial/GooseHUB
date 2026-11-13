#include <amxmodx>
#include <engine>
#include <fun>
new g_human, g_visible = 15, g_effects, g_smoke, g_lock_camera, g_camera;
new Float:g_anchor[3];
public plugin_precache() { g_smoke = precache_model("sprites/steam1.spr");precache_model("models/w_usp.mdl"); }
public plugin_init() {
 register_plugin("Local load measurement", "1", "GooseHUB");
 register_event("ResetHUD", "protect_spawn", "be");
 register_clcmd("jointeam","guard_team");
 register_clcmd("chooseteam","guard_team");
 register_clcmd("kill","guard_team");
 register_srvcmd("bench_form", "formation");
 register_srvcmd("bench_join", "join_local");
 register_srvcmd("bench_visible", "visibility");
 register_srvcmd("bench_effects", "effects");
 register_srvcmd("bench_report", "report");
 set_task(0.2,"emit_effects",1,"",0,"b");
 set_task(0.2,"lock_formation",2,"",0,"b");
}
public guard_team(id) {return id==g_human && g_lock_camera ? PLUGIN_HANDLED : PLUGIN_CONTINUE;}
public protect_spawn(id) {if(is_user_alive(id))set_user_godmode(id,1);}
public client_PreThink(id) {
 if(id!=g_human || !g_lock_camera)return;
 new Float:a[3];a[1]=180.0;entity_set_vector(id,EV_VEC_v_angle,a);entity_set_vector(id,EV_VEC_angles,a);entity_set_int(id,EV_INT_fixangle,1);entity_set_int(id,EV_INT_button,0);
}
public join_local() {
 for(new i=1;i<=32;i++) if(is_user_connected(i) && !is_user_bot(i)) {if(get_user_team(i)!=2)engclient_cmd(i,"jointeam","2");if(!is_user_alive(i))engclient_cmd(i,"joinclass","1");server_print("BENCH_JOIN %d alive=%d team=%d",i,is_user_alive(i),get_user_team(i));}
 return PLUGIN_HANDLED;
}
public formation() {
 for(new i=1;i<=32;i++) if(is_user_connected(i) && !is_user_bot(i)) {g_human=i;break;}
 if(!g_human || !is_user_alive(g_human)) {server_print("BENCH_NO_HUMAN");return PLUGIN_HANDLED;}
 g_anchor[0]=448.0;g_anchor[1]=2368.0;g_anchor[2]=-91.96875;entity_set_origin(g_human,g_anchor);
 new Float:angle[3];angle[0]=0.0;angle[1]=180.0;angle[2]=0.0;
 entity_set_vector(g_human,EV_VEC_v_angle,angle);entity_set_vector(g_human,EV_VEC_angles,angle);entity_set_int(g_human,EV_INT_fixangle,1);
 show_menu(g_human,0,"",1);client_cmd(g_human,"cancelselect");
 g_lock_camera=1;set_user_godmode(g_human,1);entity_set_int(g_human,EV_INT_movetype,MOVETYPE_NONE);
 new n=0;
 for(new i=1;i<=32;i++) if(is_user_alive(i) && i!=g_human) {
  new Float:p[3];p[0]=g_anchor[0]-160.0-float(n/5)*65.0;p[1]=g_anchor[1]+float(n%5-2)*40.0;p[2]=g_anchor[2];
  entity_set_origin(i,p);set_user_godmode(i,1);entity_set_int(i,EV_INT_solid,SOLID_NOT);entity_set_int(i,EV_INT_movetype,MOVETYPE_NONE);
  n++;
 }
 if(!is_valid_ent(g_camera))g_camera=create_entity("info_target");
 entity_set_model(g_camera,"models/w_usp.mdl");entity_set_int(g_camera,EV_INT_solid,SOLID_NOT);entity_set_int(g_camera,EV_INT_movetype,MOVETYPE_NONE);
 entity_set_int(g_camera,EV_INT_rendermode,kRenderTransTexture);entity_set_float(g_camera,EV_FL_renderamt,0.0);
 new Float:eye[3];eye[0]=g_anchor[0];eye[1]=g_anchor[1];eye[2]=g_anchor[2]+17.03125;
 entity_set_origin(g_camera,eye);entity_set_vector(g_camera,EV_VEC_angles,angle);attach_view(g_human,g_camera);
 entity_set_int(g_human,EV_INT_effects,entity_get_int(g_human,EV_INT_effects)|EF_NODRAW);
 server_print("BENCH_FORM human=%d peers=%d origin=%.2f,%.2f,%.2f",g_human,n,g_anchor[0],g_anchor[1],g_anchor[2]);
 return PLUGIN_HANDLED;
}
public lock_formation() {
 if(!g_lock_camera)return;
 new n=0;
 for(new i=1;i<=32;i++)if(is_user_alive(i)&&i!=g_human){
  new Float:p[3];p[0]=g_anchor[0]-160.0-float(n/5)*65.0;p[1]=g_anchor[1]+float(n%5-2)*40.0;p[2]=g_anchor[2];
  entity_set_origin(i,p);entity_set_int(i,EV_INT_movetype,MOVETYPE_NONE);n++;
 }
}
public visibility() {
 new text[16];read_argv(1,text,15);g_visible=str_to_num(text);new n=0;
 for(new i=1;i<=32;i++) if(is_user_alive(i) && i!=g_human) {
  new f=entity_get_int(i,EV_INT_effects);
  if(n++<g_visible) f &= ~EF_NODRAW; else f |= EF_NODRAW;
  entity_set_int(i,EV_INT_effects,f);
 }
 server_print("BENCH_VISIBLE requested=%d peers=%d",g_visible,n);return PLUGIN_HANDLED;
}
public effects() {new text[16];read_argv(1,text,15);g_effects=str_to_num(text);server_print("BENCH_EFFECTS %d",g_effects);return PLUGIN_HANDLED;}
public report() {
 new alive, visible, ct, tt, offgrid, n;
 for(new i=1;i<=32;i++) if(is_user_alive(i)) {alive++;if(get_user_team(i)==2)ct++;else if(get_user_team(i)==1)tt++;if(i!=g_human && !(entity_get_int(i,EV_INT_effects)&EF_NODRAW))visible++;}
 for(new i=1;i<=32;i++)if(is_user_alive(i)&&i!=g_human){
  new Float:p[3];entity_get_vector(i,EV_VEC_origin,p);
  if(floatabs(p[0]-(g_anchor[0]-160.0-float(n/5)*65.0))>1.0 || floatabs(p[1]-(g_anchor[1]+float(n%5-2)*40.0))>1.0)offgrid++;
  n++;
 }
 new Float:eye[3],Float:a[3];if(is_valid_ent(g_camera)){entity_get_vector(g_camera,EV_VEC_origin,eye);entity_get_vector(g_camera,EV_VEC_angles,a);}
 server_print("BENCH_CAMERA id=%d origin=%.2f,%.2f,%.2f yaw=%.2f offgrid=%d",g_camera,eye[0],eye[1],eye[2],a[1],offgrid);
 server_print("BENCH_REPORT human=%d human_alive=%d alive=%d ct=%d t=%d peers_visible=%d effects=%d",g_human,is_user_alive(g_human),alive,ct,tt,visible,g_effects);return PLUGIN_HANDLED;
}
public emit_effects() {
 if(!g_effects || !g_human)return;
 for(new i=0;i<6;i++) {
  new p[3];p[0]=floatround(g_anchor[0]-180.0-float(i/3)*60.0);p[1]=floatround(g_anchor[1]+float(i%3-1)*65.0);p[2]=floatround(g_anchor[2]+10.0);
  if(g_effects&1) {
   message_begin(MSG_BROADCAST,SVC_TEMPENTITY);write_byte(TE_SMOKE);write_coord(p[0]);write_coord(p[1]);write_coord(p[2]);write_short(g_smoke);write_byte(20);write_byte(8);message_end();
  }
  if((g_effects&2) && i<3) {
   message_begin(MSG_BROADCAST,SVC_TEMPENTITY);write_byte(TE_DLIGHT);write_coord(p[0]);write_coord(p[1]);write_coord(p[2]+30);write_byte(18);write_byte(255);write_byte(130);write_byte(60);write_byte(3);write_byte(0);message_end();
  }
 }
}
