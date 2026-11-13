#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
int wmain(int argc, wchar_t **argv) {
    printf("{\"arguments\":[");
    for (int i=1;i<argc;i++) {
        int n=WideCharToMultiByte(CP_UTF8,0,argv[i],-1,NULL,0,NULL,NULL);
        char *s=malloc(n);
        if (!s) return 2;
        WideCharToMultiByte(CP_UTF8,0,argv[i],-1,s,n,NULL,NULL);
        if(i>1) putchar(',');
        putchar('"');
        for (const unsigned char *p=(const unsigned char *)s;*p;p++) {
            if(*p=='"'||*p=='\\') {putchar('\\');putchar(*p);}
            else if(*p<32) printf("\\u%04x",*p);
            else putchar(*p);
        }
        putchar('"');free(s);
    }
    puts("]}");return 0;
}
