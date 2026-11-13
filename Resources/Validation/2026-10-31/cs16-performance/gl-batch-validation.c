#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>
#include <string.h>
static int failures;
static void pixel(const char *name, unsigned char red, unsigned char green) {
 unsigned char p[4]={0}; glReadPixels(32,32,1,1,GL_RGBA,GL_UNSIGNED_BYTE,p);
 if(p[0]!=red || p[1]!=green || p[2]!=0){printf("FAIL %s pixel %u %u %u\n",name,p[0],p[1],p[2]);failures++;}
 else printf("PASS %s\n",name);
}
static void quad(void) {
 GLfloat v[3]={-1,-1,0}; glBegin(GL_QUADS);glTexCoord2f(0,0);glVertex3fv(v);
 v[0]=1;glTexCoord2f(1,0);glVertex3fv(v);v[1]=1;glTexCoord2f(1,1);glVertex3fv(v);
 v[0]=-1;glTexCoord2f(0,1);glVertex3fv(v);v[0]=0;v[1]=0;glEnd();
}
int main(void) {
 WNDCLASSA wc={0};wc.lpfnWndProc=DefWindowProcA;wc.hInstance=GetModuleHandleA(NULL);wc.lpszClassName="GooseGLBatchValidation";RegisterClassA(&wc);
 HWND w=CreateWindowA(wc.lpszClassName,"OpenGL validation",WS_OVERLAPPEDWINDOW|WS_VISIBLE,0,0,128,128,0,0,wc.hInstance,0);
 ShowWindow(w,SW_SHOW);UpdateWindow(w);MSG msg;while(PeekMessage(&msg,0,0,0,PM_REMOVE)){TranslateMessage(&msg);DispatchMessage(&msg);}
 HDC dc=GetDC(w);PIXELFORMATDESCRIPTOR d={sizeof(d),1,PFD_DRAW_TO_WINDOW|PFD_SUPPORT_OPENGL|PFD_DOUBLEBUFFER,PFD_TYPE_RGBA,32,0,0,0,0,0,0,8,0,0,0,0,0,24,8,0,PFD_MAIN_PLANE,0,0,0,0};
 int pf=ChoosePixelFormat(dc,&d);if(!pf||!SetPixelFormat(dc,pf,&d)){printf("FAIL pixel format\n");return 1;}
 HGLRC a=wglCreateContext(dc),b=wglCreateContext(dc);if(!a||!b||!wglMakeCurrent(dc,a)){printf("FAIL contexts\n");return 1;}
 printf("RENDERER %s\nVERSION %s\nMESA_CLIENT_POINTER %d\n",glGetString(GL_RENDERER),glGetString(GL_VERSION),strstr((const char*)glGetString(GL_EXTENSIONS),"GL_MESA_map_buffer_client_pointer")!=NULL);
 glViewport(0,0,64,64);glDisable(GL_DITHER);glClearColor(0,0,0,1);glClear(GL_COLOR_BUFFER_BIT);
 glColor4ub(0,255,0,255);quad();pixel("pointer values are captured before mutation",0,255);
 glColor4f(1,0,0,1);wglMakeCurrent(dc,b);glViewport(0,0,64,64);glDisable(GL_DITHER);glColor4f(0,1,0,1);quad();pixel("second context",0,255);
 wglMakeCurrent(dc,a);quad();pixel("pending state survives context switch",255,0);
 GLuint list=glGenLists(1);glNewList(list,GL_COMPILE);glColor3f(0,1,0);quad();glEndList();glColor3f(1,0,0);glCallList(list);pixel("display list compile and playback",0,255);glDeleteLists(list,1);
 glColor3f(1,0,0);glBegin(GL_TRIANGLES);for(int i=0;i<500;i++){glVertex3f(-1,-1,0);glVertex3f(1,-1,0);glVertex3f(0,1,0);}glEnd();pixel("bounded batches preserve an open primitive",255,0);
 while(glGetError()!=GL_NO_ERROR){}glBegin(0xdead);GLenum err=glGetError();if(err!=GL_INVALID_ENUM){printf("FAIL invalid enum error %x\n",err);failures++;}else printf("PASS error retrieval flushes pending commands\n");
 printf("RESULT failures=%d\n",failures);wglMakeCurrent(0,0);wglDeleteContext(a);wglDeleteContext(b);ReleaseDC(w,dc);DestroyWindow(w);return failures?1:0;
}
