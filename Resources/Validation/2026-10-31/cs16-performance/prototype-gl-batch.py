from pathlib import Path
import re, shutil
r=Path(__file__).resolve().parent
src=r.parent/'wine-current/source/dlls/opengl32'
backup=r/'wine-opengl-before-batch'
backup.mkdir(exist_ok=True)
for name in ['unixlib.h','wgl.c','unix_thunks.c']:
    if not (backup/name).exists(): shutil.copy2(src/name,backup/name)
    else: shutil.copy2(backup/name,src/name)
scalars=['glBegin','glEnd','glVertex2f','glVertex3f','glVertex4f','glTexCoord1f','glTexCoord2f','glTexCoord3f','glTexCoord4f','glMultiTexCoord2f','glMultiTexCoord2fARB','glMultiTexCoord2fSGIS','glColor3f','glColor4f','glColor4ub','glNormal3f','glEdgeFlag']
vectors={'glVertex2fv':('v',8),'glVertex3fv':('v',12),'glVertex4fv':('v',16),'glTexCoord1fv':('v',4),'glTexCoord2fv':('v',8),'glTexCoord3fv':('v',12),'glTexCoord4fv':('v',16),'glMultiTexCoord2fv':('v',8),'glMultiTexCoord2fvARB':('v',8),'glColor3fv':('v',12),'glColor4fv':('v',16),'glColor4ubv':('v',4),'glNormal3fv':('v',12)}
header=(src/'unixlib.h').read_text()
all_names=scalars+list(vectors)
for name in all_names:
    assert 'struct '+name+'_params' in header,name
    assert 'unix_'+name+',' in header,name
protocol='''
/* Test-only bounded command buffer for the i386/Unix transition experiment. */
#define GOOSE_GL_BATCH_CAPACITY 128
struct goose_gl_command { UINT code; BYTE args[24]; BYTE data[16]; };
struct goose_gl_batch { UINT count; BOOL flushing; struct goose_gl_command commands[GOOSE_GL_BATCH_CAPACITY]; };
'''
header=header.replace('enum unix_funcs\n',protocol+'\nenum unix_funcs\n')
header=header.replace('    funcs_count\n','    unix_goose_gl_batch,\n    funcs_count\n')
header=header.replace('#define UNIX_CALL( func, params ) WINE_UNIX_CALL( unix_ ## func, params )', '''#ifdef __i386__
extern NTSTATUS goose_gl_unix_call( unsigned int code, void *args );
#define UNIX_CALL( func, params ) goose_gl_unix_call( unix_ ## func, params )
#else
#define UNIX_CALL( func, params ) WINE_UNIX_CALL( unix_ ## func, params )
#endif''')
(src/'unixlib.h').write_text(header)
code='''
#ifdef __i386__
#define WINE_GL_RESERVED_BATCH 6
static BOOL goose_gl_batch_enabled;

static NTSTATUS goose_flush_gl_batch( struct goose_gl_batch *batch )
{
    NTSTATUS status;
    if (!batch || !batch->count || batch->flushing) return STATUS_SUCCESS;
    batch->flushing = TRUE;
    status = WINE_UNIX_CALL( unix_goose_gl_batch, batch );
    batch->count = 0;
    batch->flushing = FALSE;
    return status;
}

NTSTATUS goose_gl_unix_call( unsigned int code, void *args )
{
    struct goose_gl_batch *batch = NtCurrentTeb()->glReserved1[WINE_GL_RESERVED_BATCH];
    struct goose_gl_command *command;
    UINT size = 0;
    NTSTATUS status;
    if (!batch || batch->flushing) return WINE_UNIX_CALL( code, args );
    switch (code)
    {
'''
for name in all_names:
    code+=f'    case unix_{name}: size = sizeof(struct {name}_params); break;\n'
code+='''    default:
        if ((status = goose_flush_gl_batch( batch ))) return status;
        return WINE_UNIX_CALL( code, args );
    }
    if (batch->count == GOOSE_GL_BATCH_CAPACITY && (status = goose_flush_gl_batch( batch ))) return status;
    command = &batch->commands[batch->count++];
    command->code = code;
    memcpy( command->args, args, size );
    switch (code)
    {
'''
for name,(field,size) in vectors.items():
    code+=f'''    case unix_{name}:
        memcpy( command->data, ((struct {name}_params *)args)->{field}, {size} );
        ((struct {name}_params *)command->args)->{field} = (void *)command->data;
        break;
'''
code+='''    }
    return STATUS_SUCCESS;
}
#endif
'''
p=src/'wgl.c';s=p.read_text();s=s.replace('static const MAT2 identity',code+'\nstatic const MAT2 identity')
s=s.replace('        /* fallthrough */\n    case DLL_THREAD_ATTACH:', '''#ifdef __i386__
        { char enabled[2]; goose_gl_batch_enabled = GetEnvironmentVariableA( "GOOSE_GL_BATCH", enabled, sizeof(enabled) ) && enabled[0] == '1'; }
#endif
        /* fallthrough */
    case DLL_THREAD_ATTACH:''')
s=s.replace('        break;\n\n    case DLL_PROCESS_DETACH:', '''#ifdef __i386__
        if (goose_gl_batch_enabled) NtCurrentTeb()->glReserved1[WINE_GL_RESERVED_BATCH] = calloc( 1, sizeof(struct goose_gl_batch) );
#endif
        break;

    case DLL_PROCESS_DETACH:''')
s=s.replace('    case DLL_THREAD_DETACH:\n', '''    case DLL_THREAD_DETACH:
#ifdef __i386__
        goose_flush_gl_batch( NtCurrentTeb()->glReserved1[WINE_GL_RESERVED_BATCH] );
        free( NtCurrentTeb()->glReserved1[WINE_GL_RESERVED_BATCH] );
        NtCurrentTeb()->glReserved1[WINE_GL_RESERVED_BATCH] = NULL;
#endif
''')
p.write_text(s)
p=src/'unix_thunks.c';s=p.read_text()
s=s.replace('const unixlib_entry_t __wine_unix_call_funcs[] =','''static NTSTATUS goose_batch_unavailable( void *args ) { return STATUS_NOT_IMPLEMENTED; }

const unixlib_entry_t __wine_unix_call_funcs[] =''')
s=s.replace('    ext_wglSwapIntervalEXT,\n};','    ext_wglSwapIntervalEXT,\n    goose_batch_unavailable,\n};',1)
backend='''
static NTSTATUS goose_batch_commands( void *args )
{
    struct goose_gl_batch *batch = args;
    UINT i;
    NTSTATUS status;
    if (batch->count > GOOSE_GL_BATCH_CAPACITY) return STATUS_INVALID_PARAMETER;
    for (i = 0; i < batch->count; i++)
    {
        struct goose_gl_command *cmd = &batch->commands[i];
        switch (cmd->code)
        {
'''
for name in all_names:
    callee=('wow64_gl_' if 'static NTSTATUS wow64_gl_'+name+'(' in s else 'wow64_ext_')+name
    backend+=f'        case unix_{name}: status = {callee}( cmd->args ); break;\n'
backend+='''        default: return STATUS_INVALID_PARAMETER;
        }
        if (status) return status;
    }
    return STATUS_SUCCESS;
}

'''
s=s.replace('const unixlib_entry_t __wine_unix_call_wow64_funcs[] =',backend+'const unixlib_entry_t __wine_unix_call_wow64_funcs[] =')
s=s.replace('    wow64_ext_wglSwapIntervalEXT,\n};','    wow64_ext_wglSwapIntervalEXT,\n    goose_batch_commands,\n};',1)
assert s.count('    goose_batch_unavailable,')==1
assert s.count('    goose_batch_commands,')==1
p.write_text(s)
print('Prototype written only to the disposable Wine source snapshot')
