#!/usr/bin/env python3
"""Fetch, build and install one GooseHUB component from its public source repository."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

EVENT_PREFIX = '@goose '
ACTIVE = None
COMPONENT = None
PERCENT = 0


class SetupError(RuntimeError):
    pass


class BuildLog:
    def __init__(self, console, path):
        self.console, self.file = console, path.open('w')

    def write(self, text):
        self.console.write(text)
        return self.file.write(text)

    def flush(self):
        self.console.flush()
        self.file.flush()


def event(phase, message, percent=None):
    global PERCENT
    previous = PERCENT
    if percent is not None:
        PERCENT = max(PERCENT, min(100, percent))
    if not message and round(previous, 1) == round(PERCENT, 1) and phase not in ('complete', 'failed'):
        return
    print(EVENT_PREFIX + json.dumps({'component': COMPONENT, 'phase': phase,
                                    'message': message, 'percent': round(PERCENT, 1)}), flush=True)


def output_fraction(line):
    """Read completed work reported by Git, Ninja, or the MetalGoose builder."""
    if line.startswith('@metalgoose '):
        value = json.loads(line.removeprefix('@metalgoose '))
        return value['completed'] / max(1, value['total'])
    match = re.search(r'\[(\d+)/(\d+)\]', line)
    if match:
        return int(match[1]) / max(1, int(match[2]))
    match = re.search(r'(?:Receiving objects|Resolving deltas):\s+(\d+)%', line)
    if match:
        return int(match[1]) / 100
    return None


def run(args, *, cwd=None, env=None, capture=False, progress=None, completed_targets=None):
    global ACTIVE
    args = [str(a) for a in args]
    print('+ ' + ' '.join(args), flush=True)
    child = subprocess.Popen(args, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, errors='replace', start_new_session=True)
    ACTIVE = child
    output = []
    try:
        completed = 0
        for line in child.stdout:
            if capture:
                output.append(line)
            else:
                print(line, end='', flush=True)
            if progress is not None:
                fraction = output_fraction(line)
                if completed_targets and re.search(r": update target '[^']+' due to:", line):
                    completed += 1
                    fraction = completed / completed_targets
                if fraction is not None:
                    event('build', '', progress[0] + min(1, fraction) * (progress[1] - progress[0]))
        code = child.wait()
        if code:
            detail = ''.join(output)[-2000:] if capture else ''
            raise SetupError(f'{Path(args[0]).name} exited with {code}. {detail}')
        if progress is not None:
            event('build', '', progress[1])
        return ''.join(output)
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        child.stdout.close()
        ACTIVE = None


def cancelled(signum, frame):
    raise SetupError('Installation cancelled.')


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def git(path, *args, capture=True, progress=None):
    # Public sources must work without the user's Git credentials or global rewrites.
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_CONFIG_GLOBAL='/dev/null',
               GIT_CONFIG_NOSYSTEM='1', GIT_ASKPASS='/usr/bin/false')
    env.pop('GIT_CONFIG_COUNT', None)
    return run(['git', '-c', 'credential.helper=', '-c', 'http.extraHeader=', '-C', path, *args],
               env=env, capture=capture, progress=progress).strip()


def fetch_repository(spec, root, *, local=False):
    name, revision = spec['directory'], spec['revision']
    if Path(name).name != name or name in ('', '.', '..'):
        raise SetupError('Invalid repository directory in engine-lock.json')
    path = root / name
    if path.is_symlink():
        raise SetupError(f'Source directory must not be a symbolic link: {path}')
    if local:
        if not (path / '.git').exists():
            raise SetupError(f'Local source repository is missing: {path}')
        return path
    if not re.fullmatch('[a-f0-9]{40}', revision):
        raise SetupError(f'Invalid source revision for {name}.')
    if not path.exists():
        # A failed clone is owned by this invocation; existing directories are never removed.
        temporary = Path(tempfile.mkdtemp(prefix=f'.{name}-', dir=root))
        try:
            git(temporary, 'init', capture=False)
            git(temporary, 'remote', 'add', 'origin', spec['url'])
            git(temporary, 'fetch', '--progress', '--depth=1', '--no-tags', 'origin', revision,
                capture=False, progress=(8, 16))
            git(temporary, 'checkout', '--detach', 'FETCH_HEAD')
            temporary.rename(path)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
    else:
        if not (path / '.git').exists():
            raise SetupError(f'{path} is not a Git repository. Move it aside and retry.')
        origin = git(path, 'remote', 'get-url', 'origin')
        if origin.removesuffix('.git').lower() != spec['url'].removesuffix('.git').lower():
            raise SetupError(f'{path} belongs to a different repository. Move it aside and retry.')
        if git(path, 'status', '--porcelain', '--untracked-files=normal', '--ignore-submodules=untracked'):
            raise SetupError(f'{path} has uncommitted changes. Commit them and retry; nothing was overwritten.')
        git(path, 'fetch', '--progress', '--no-tags', 'origin', revision, capture=False, progress=(8, 16))
        wanted = git(path, 'rev-parse', 'FETCH_HEAD^{commit}')
        current = git(path, 'rev-parse', 'HEAD')
        if current != wanted:
            # Do not detach or reset a user's development checkout.
            git(path, 'merge', '--ff-only', wanted, capture=False)
        if git(path, 'rev-parse', 'HEAD') != wanted:
            raise SetupError(f'{path} is ahead of the required revision. Local commits were retained.')
    # FEX test-bin submodules are not build dependencies and are not downloaded.
    if name == 'fex-adrenalin-edition':
        modules = ['External/vixl', 'External/fmt', 'External/xxhash', 'External/Catch2',
                   'External/jemalloc_glibc', 'External/tracy', 'External/range-v3',
                   'External/zydis', 'External/unordered_dense', 'External/rpmalloc',
                   'Source/Common/cpp-optparse', 'External/Vulkan-Headers', 'External/drm-headers']
        git(path, 'submodule', 'update', '--init', '--recursive', '--', *modules, capture=False)
    elif name == 'dxmt-adrenalin-edition':
        git(path, 'submodule', 'update', '--init', '--recursive', capture=False)
    event('sources', '', 18)
    return path


def tools(cache, spec, component):
    event('tools', 'Checking build tools')
    if sys.platform != 'darwin' or os.uname().machine != 'arm64':
        raise SetupError('Engine source builds require an Apple Silicon Mac.')
    run(['xcrun', '--find', 'clang'], capture=True)
    run(['xcrun', '--find', 'metal'], capture=True)
    if component == 'metalgoose':
        event('tools', '', 8)
        return dict(os.environ), Path('/opt/homebrew')
    brew = shutil.which('brew') or '/opt/homebrew/bin/brew'
    if not Path(brew).is_file():
        raise SetupError('Install Homebrew and Xcode with the Metal toolchain, then retry.')
    prefix = Path(run([brew, '--prefix'], capture=True).strip())
    formulae = {
        'wine': ['make', 'bison', 'pkgconf', 'llvm', 'lld', 'mingw-w64', 'freetype', 'gnutls',
                 'sdl2-compat', 'sdl3', 'vulkan-loader', 'molten-vk', 'gstreamer', 'dbus', 'cups', 'samba', 'unixodbc'],
        'fex': ['cmake', 'ninja', 'ccache'],
        'dxmt': ['meson', 'ninja', 'ccache', 'pkgconf', 'llvm', 'lld', 'mingw-w64']
    }[component]
    installed = set(run([brew, 'list', '--formula'], capture=True).splitlines())
    missing = [f for f in formulae if f not in installed]
    if missing:
        event('tools', 'Installing build and media dependencies')
        run([brew, 'install', *missing], env=dict(os.environ, HOMEBREW_NO_AUTO_UPDATE='1'))
    compiler_root = cache / 'Toolchains' / spec['directory']
    if component in ('fex', 'dxmt') and not (compiler_root / 'bin/arm64ec-w64-mingw32-clang').is_file():
        if not re.fullmatch('[a-f0-9]{64}', spec['sha256']):
            raise SetupError('The compiler download checksum is missing.')
        event('tools', 'Downloading the compiler toolchain')
        compiler_root.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=compiler_root.parent) as temporary:
            folder = Path(temporary)
            archive = folder / 'compiler.tar.xz'
            with urllib.request.urlopen(spec['url'], timeout=60) as response, archive.open('wb') as output:
                length = int(response.headers.get('Content-Length', '0'))
                count = 0
                while True:
                    data = response.read(1024 * 1024)
                    if not data:
                        break
                    output.write(data)
                    count += len(data)
                    if length:
                        event('tools', '', 2 + 5 * count / length)
            if digest(archive) != spec['sha256']:
                raise SetupError('The compiler archive checksum does not match.')
            with tarfile.open(archive) as tar:
                if hasattr(tarfile, 'data_filter'):
                    tar.extractall(folder, filter='data')
                else:
                    # Python shipped with older Xcode lacks extraction filters.
                    for member in tar.getmembers():
                        target = (folder / member.name).resolve()
                        if folder not in target.parents or member.isdev():
                            raise SetupError('Unsafe compiler archive member.')
                        if member.issym() or member.islnk():
                            target = (target.parent / member.linkname).resolve()
                            if folder not in target.parents:
                                raise SetupError('Unsafe compiler archive link.')
                    tar.extractall(folder)
            extracted = folder / spec['directory']
            if not (extracted / 'bin/arm64ec-w64-mingw32-clang').is_file():
                raise SetupError('The compiler archive is incomplete.')
            extracted.rename(compiler_root)
    env = dict(os.environ)
    env['PATH'] = ':'.join(str(p) for p in [compiler_root / 'bin', prefix / 'opt/llvm/bin',
                       prefix / 'opt/lld/bin', prefix / 'opt/bison/bin', prefix / 'bin']) + ':/usr/bin:/bin:/usr/sbin:/sbin'
    env['PKG_CONFIG_PATH'] = f'{prefix}/lib/pkgconfig:{prefix}/share/pkgconfig'
    env['GOOSE_LLVM_ROOT'] = str(prefix / 'opt/llvm')
    env['NINJA_STATUS'] = '[%f/%t] '
    event('tools', '', 8)
    return env, prefix


def make(build, env, jobs, targets=(), progress=(18, 70), extra=()):
    # --output-sync flushes each target's trace after its recipe finishes.
    command = ['gmake', '--trace', '--output-sync=target', f'-j{jobs}', *extra, *targets]
    plan = run([*command, '-n'], cwd=build, env=env, capture=True)
    total = len(re.findall(r": update target '[^']+' due to:", plan))
    run(command, cwd=build, env=env, progress=progress, completed_targets=max(1, total))


def build_wine(source, build, env, jobs, entitlements):
    event('wine', 'Building Wine Adrenalin Edition')
    build.mkdir(parents=True, exist_ok=True)
    if not (build / 'Makefile').exists():
        run([source / 'configure', '--enable-archs=arm64ec,aarch64,i386', '--without-x',
             '--without-pulse', '--disable-tests', '--prefix=/usr/local',
             'CC=/usr/bin/clang', 'CXX=/usr/bin/clang++', f'aarch64_CC={env["GOOSE_LLVM_ROOT"]}/bin/clang',
             f'arm64ec_CC={env["GOOSE_LLVM_ROOT"]}/bin/clang', 'i386_CC=i686-w64-mingw32-gcc',
             f'x86_64_CC={env["GOOSE_LLVM_ROOT"]}/bin/clang', 'CFLAGS=-g -O2',
             'CXXFLAGS=-g -O2', 'LDFLAGS=-Wl,-headerpad_max_install_names'], cwd=build, env=env)
    run(['gmake', 'depend'], cwd=build, env=env)
    make(build, env, jobs)
    # Keep the accelerated PE32 OpenGL module separate from the regular fallback.
    overlay = build.parent / 'legacy-opengl/i386-windows'
    overlay.mkdir(parents=True, exist_ok=True)
    objects = [build / f'dlls/opengl32/i386-windows/{n}.o' for n in ['thunks', 'wgl']]
    source_key = hashlib.sha256((git(source, 'rev-parse', 'HEAD') +
                               git(source, 'diff', 'HEAD', '--binary') +
                               digest(build / 'include/config.h')).encode()).hexdigest()
    stamp = overlay / 'source.sha256'
    if not (overlay / 'opengl32.dll').is_file() or not stamp.is_file() or stamp.read_text().strip() != source_key:
        for p in objects:
            p.unlink(missing_ok=True)
        try:
            make(build, env, jobs, ['dlls/opengl32/i386-windows/opengl32.dll'], (70, 73),
                 ['i386_CFLAGS=-g -O2 -DWINE_OPENGL_BATCHING'])
            shutil.copy2(build / 'dlls/opengl32/i386-windows/opengl32.dll', overlay / 'opengl32.dll')
        finally:
            for p in objects:
                p.unlink(missing_ok=True)
        make(build, env, jobs, ['dlls/opengl32/i386-windows/opengl32.dll'], (73, 75))
        stamp.write_text(source_key + '\n')
    install = build.parent / 'install'
    run(['gmake', 'install-lib', f'DESTDIR={install}'], cwd=build, env=env, progress=(75, 78))
    return install / 'usr/local'


def build_fex(source, build, env, jobs):
    event('fex', 'Building FEX Adrenalin Edition')
    for name, triple, target in [('arm64ec', 'arm64ec-w64-mingw32', 'arm64ecfex'),
                                 ('wow64', 'aarch64-w64-mingw32', 'wow64fex')]:
        output = build / name
        run(['cmake', '-S', source, '-B', output, '-G', 'Ninja',
             f'-DCMAKE_TOOLCHAIN_FILE={source}/Data/CMake/toolchain_mingw.cmake',
             f'-DMINGW_TRIPLE={triple}', '-DCMAKE_BUILD_TYPE=Release', '-DENABLE_LTO=False',
             '-DBUILD_TESTING=False', '-DBUILD_FEXCONFIG=False', '-DENABLE_JEMALLOC_GLIBC_ALLOC=False',
             '-DENABLE_GDB_SYMBOLS=False', '-DTUNE_CPU=none'], env=env)
        interval = (18, 47) if name == 'arm64ec' else (47, 76)
        run(['cmake', '--build', output, '--target', target, '--parallel', str(jobs)], env=env, progress=interval)
    native = build / 'unix'
    native.mkdir(exist_ok=True)
    for name in ['arm64ecfex', 'wow64fex']:
        run(['/usr/bin/clang++', '-std=c++20', '-O2', '-arch', 'arm64', '-dynamiclib',
             '-Wl,-headerpad_max_install_names', f'-Wl,-install_name,@rpath/lib{name}.so',
             source / 'Source/Windows/UnixLib/FEXUnixLib.cpp', '-o', native / f'lib{name}.so'], env=env)


def build_dxmt(source, build, wine_build, env, prefix, jobs):
    event('dxmt', 'Building DXMT Adrenalin Edition')
    for name, cross in [('arm64ec', 'build-arm64ec.txt'), ('x86', 'build-win32.txt')]:
        output = build / name
        if not (output / 'build.ninja').exists():
            run(['meson', 'setup', output, source, '--cross-file', source / cross,
                 '--buildtype=release', '--prefix=/', f'-Dnative_llvm_path={prefix}/opt/llvm',
                 '-Db_lto=false', f'-Dwine_build_path={wine_build}'], env=env)
        interval = (18, 47) if name == 'arm64ec' else (47, 78)
        run(['meson', 'compile', '-C', output, '-j', str(jobs)], env=env, progress=interval)
        run(['meson', 'install', '-C', output, '--no-rebuild', '--destdir', build / f'{name}-install'], env=env)


def copy_tree(source, destination):
    shutil.copytree(source, destination, symlinks=True)


def macho(path):
    if not path.is_file() or path.is_symlink():
        return False
    with path.open('rb') as f:
        return f.read(4) in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe')


class NativeLibraries:
    def __init__(self, root, prefix, env, entitlements, known_unix=()):
        self.root, self.prefix, self.env, self.entitlements = root, prefix, env, entitlements
        self.dependencies = root / 'Dependencies/arm64'
        self.dependencies.mkdir(parents=True)
        self.seen = set()
        self.origins = {}
        self.known_unix = set(known_unix)

    def library(self, source):
        source = Path(source)
        destination = self.dependencies / source.name
        if not source.is_file():
            raise SetupError(f'Native dependency is missing: {source}')
        if not destination.exists():
            shutil.copy2(source.resolve(), destination)
            destination.chmod(destination.stat().st_mode | 0o200)
            self.origins[destination] = source.resolve()
            self.relink(destination)
        return destination

    def relink(self, path, sonames=()):
        if path in self.seen:
            return
        self.seen.add(path)
        path.chmod(path.stat().st_mode | 0o200)
        data = path.read_bytes()
        for old, new in sonames:
            if len(new) > len(old):
                raise SetupError(f'Dependency name does not fit in {path.name}')
            data = data.replace(old, new.ljust(len(old), b'\0'))
        path.write_bytes(data)
        commands = []
        info = run(['otool', '-l', path], capture=True)
        rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset', info)
        origin = self.origins.get(path, path)
        identity = run(['otool', '-D', path], capture=True).splitlines()[1:]
        identity = identity[0].strip() if identity else None
        for line in run(['otool', '-L', path], capture=True).splitlines()[1:]:
            dependency = line.strip().split(' (')[0]
            if dependency == identity or dependency.startswith(('/System/', '/usr/lib/')):
                continue
            basename = Path(dependency).name
            # Wine and winemetal link to each other's Unix modules.
            internal = self.root / 'Wine/lib/wine/aarch64-unix' / basename
            if internal.is_file() or basename in self.known_unix:
                target = '@loader_path/' + os.path.relpath(internal, path.parent)
            else:
                source = Path(dependency)
                if not source.is_absolute():
                    candidates = []
                    for directory in rpaths:
                        directory = directory.replace('@loader_path', str(origin.parent))
                        if directory.startswith('/'):
                            candidates.append(Path(directory) / basename)
                    candidates += [origin.parent / basename, self.prefix / 'lib' / basename]
                    source = next((p for p in candidates if p.is_file()), candidates[-1])
                self.library(source)
                target = '@rpath/' + basename
            if target != dependency:
                commands += ['-change', dependency, target]
        for rpath in rpaths:
            commands += ['-delete_rpath', rpath]
        commands += ['-add_rpath', '@loader_path/' + os.path.relpath(self.dependencies, path.parent)]
        if identity:
            commands += ['-id', '@rpath/' + path.name]
        run(['install_name_tool', *commands, path], capture=True)
        sign = ['codesign', '--force', '--sign', '-']
        if path.name == 'wine':
            sign += ['--entitlements', self.entitlements]
        run([*sign, path], capture=True)


# This fragment replaces the old all-at-once staging path.
def put(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


FEX_FILES = ['Wine/lib/wine/aarch64-windows/' + name for name in
             ['libarm64ecfex.dll', 'libwow64fex.dll', 'xtajit64.dll', 'xtajit.dll']] + [
             'Wine/lib/wine/aarch64-unix/libarm64ecfex.so', 'Wine/lib/wine/aarch64-unix/libwow64fex.so']
BRIDGE_FILES = ['Wine/lib/wine/' + arch + '/winemetal.dll' for arch in ['aarch64-windows', 'i386-windows']] + [
                'Wine/lib/wine/aarch64-unix/winemetal.so']
DXMT_DLLS = ['d3d8.dll', 'd3d9.dll', 'd3d10core.dll', 'd3d11.dll', 'd3d12.dll', 'dxgi.dll', 'winemetal.dll']
REQUIRED_BY_COMPONENT = {
    'wine': ['Wine/bin/wine', 'Wine/bin/wineserver', 'Wine/share/wine/wine.inf',
             'Vulkan/icd.d/MoltenVK_icd.json', 'Dependencies/arm64/libMoltenVK.dylib',
             'Media/bin/gst-plugin-scanner', 'LegacyOpenGL/i386-windows/opengl32.dll',
             'LegacyOpenGL/aarch64-unix/opengl32.so'],
    'fex': FEX_FILES,
    'dxmt': BRIDGE_FILES + ['Config/dxmt.conf'] + [f'DXMT/{arch}/{dll}' for arch in ['arm64ec', 'x86'] for dll in DXMT_DLLS],
    'metalgoose': ['MetalGoose/bin/metalgoose-backend', 'MetalGoose/bin/default.metallib']
}
REQUIRED = [p for paths in REQUIRED_BY_COMPONENT.values() for p in paths]


def stage_wine(install_root, build, root, prefix):
    copy_tree(install_root, root / 'Wine')
    # These slots belong to FEX/DXMT, including when those are installed first.
    for name in FEX_FILES + BRIDGE_FILES:
        (root / name).unlink(missing_ok=True)
    put(build / 'Wine/legacy-opengl/i386-windows/opengl32.dll', root / 'LegacyOpenGL/i386-windows/opengl32.dll')
    put(root / 'Wine/lib/wine/aarch64-unix/opengl32.so', root / 'LegacyOpenGL/aarch64-unix/opengl32.so')
    gst = prefix / 'opt/gstreamer'
    plugins = ['coreelements', 'app', 'playback', 'audioconvert', 'audioresample',
               'typefindfunctions', 'videoconvertscale', 'videofilter', 'volume',
               'isomp4', 'matroska', 'ogg', 'wavparse', 'avi', 'id3demux', 'asf',
               'mpegpsdemux', 'mpegtsdemux', 'libav', 'audioparsers', 'videoparsersbad']
    for name in plugins:
        p = gst / 'lib/gstreamer-1.0' / f'libgst{name}.dylib'
        put(p.resolve(), root / 'Media/gstreamer-1.0' / p.name)
    put((gst / 'libexec/gstreamer-1.0/gst-plugin-scanner').resolve(), root / 'Media/bin/gst-plugin-scanner')
    icd = root / 'Vulkan/icd.d/MoltenVK_icd.json'
    icd.parent.mkdir(parents=True)
    icd.write_text(json.dumps({'file_format_version': '1.0.0', 'ICD': {
        'library_path': '../../Dependencies/arm64/libMoltenVK.dylib', 'api_version': '1.4.0'}}) + '\n')


def stage_component(component, source, build, root, prefix, env, support, install_root=None):
    event('install', '', 78)
    if component == 'wine':
        stage_wine(install_root, build, root, prefix)
    elif component == 'fex':
        for guest, name, alias in [('arm64ec', 'libarm64ecfex.dll', 'xtajit64.dll'),
                                   ('wow64', 'libwow64fex.dll', 'xtajit.dll')]:
            put(build / f'FEX/{guest}/Bin' / name, root / 'Wine/lib/wine/aarch64-windows' / name)
            put(build / f'FEX/{guest}/Bin' / name, root / 'Wine/lib/wine/aarch64-windows' / alias)
            put(build / 'FEX/unix' / name.replace('.dll', '.so'),
                root / 'Wine/lib/wine/aarch64-unix' / name.replace('.dll', '.so'))
    elif component == 'dxmt':
        for arch, original in [('arm64ec', 'aarch64-windows'), ('x86', 'i386-windows')]:
            destination = root / f'DXMT/{arch}'
            for name in DXMT_DLLS:
                put(build / f'DXMT/{arch}-install' / original / name, destination / name)
                if name != 'winemetal.dll':
                    with (destination / name).open('r+b') as f:
                        f.seek(64)
                        if f.read(16) == b'Wine builtin DLL':
                            f.seek(64)
                            f.write(b'\0' * 17)
            put(destination / 'winemetal.dll', root / 'Wine/lib/wine' / original / 'winemetal.dll')
        put(build / 'DXMT/arm64ec-install/aarch64-unix/winemetal.so', root / BRIDGE_FILES[-1])
        put(source / 'dxmt.conf', root / 'Config/dxmt.conf')
    elif component == 'metalgoose':
        for name in ['metalgoose-backend', 'default.metallib']:
            put(build / 'MetalGoose' / name, root / 'MetalGoose/bin' / name)

    known = [p.name for p in (build / 'Wine/install/usr/local/lib/wine/aarch64-unix').glob('*')]
    libraries = NativeLibraries(root, prefix, env, support / 'Wine.entitlements', known_unix=known)
    sonames = []
    if component == 'wine':
        config = (build / 'Wine/build/include/config.h').read_text()
        for name in re.findall(r'^#define SONAME_\w+ "([^"]+)"', config, re.M):
            path = Path(name) if name.startswith('/') else prefix / 'lib' / name
            libraries.library(path)
            if name.startswith('/'):
                sonames.append((name.encode() + b'\0', ('@rpath/' + path.name).encode() + b'\0'))
        for name in ['libSDL3.dylib', 'libMoltenVK.dylib']:
            libraries.library(prefix / 'lib' / name)
    native = [p for p in sorted(root.rglob('*')) if macho(p)]
    for index, p in enumerate(native, 1):
        libraries.relink(p, sonames if root / 'Wine' in p.parents else ())
        event('install', '', 78 + 8 * index / max(1, len(native)))
    licenses = root / 'Licenses'
    filename = 'COPYING.LIB' if component == 'wine' else 'LICENSE'
    put(source / filename, licenses / component / filename)
    for path in libraries.dependencies.iterdir():
        origin = prefix / 'lib' / path.name
        if origin.is_file():
            parts = origin.resolve().parts
            if 'Cellar' not in parts:
                continue
            index = parts.index('Cellar')
            keg = Path(*parts[:index + 3])
            for item in [*keg.glob('LICENSE*'), *keg.glob('COPYING*')]:
                if item.is_file():
                    put(item, licenses / 'Dependencies' / keg.parent.name / keg.name / item.name)
    event('install', '', 86)


def read_manifest(root):
    path = root / 'manifest.json'
    if not path.is_file():
        return {}
    return json.loads(path.read_text())


def components_of(manifest):
    if manifest.get('schemaVersion') == 3:
        return dict(manifest.get('components', {}))
    if manifest.get('installationComplete'):
        # Adopt a complete runtime from the earlier installer without rebuilding it.
        return {name: dict(manifest.get(name, {}), files=[a['path'] for a in manifest.get('assets', [])
                    if legacy_owner(a['path']) == name]) for name in REQUIRED_BY_COMPONENT}
    return {}


def legacy_owner(path):
    if path in FEX_FILES or path.startswith('Licenses/fex/'):
        return 'fex'
    if path in BRIDGE_FILES or path.startswith(('DXMT/', 'Config/', 'Licenses/dxmt/')):
        return 'dxmt'
    if path.startswith(('MetalGoose/', 'Licenses/metalgoose/')):
        return 'metalgoose'
    return 'wine'


def clone_tree(source, destination):
    try:
        run(['/bin/cp', '-cRp', source, destination], capture=True)
    except SetupError:
        if destination.exists():
            shutil.rmtree(destination)
        copy_tree(source, destination)


def merge_component(previous, package, staging, component, record):
    components = components_of(read_manifest(previous))
    if previous.exists():
        clone_tree(previous, staging)
    else:
        staging.mkdir()
    other_files = {p for key, value in components.items() if key != component for p in value.get('files', [])}
    for name in components.get(component, {}).get('files', []):
        if name not in other_files:
            (staging / name).unlink(missing_ok=True)
    files = sorted(str(p.relative_to(package)) for p in package.rglob('*') if p.is_file() or p.is_symlink())
    shutil.copytree(package, staging, dirs_exist_ok=True, symlinks=True)
    components[component] = dict(record, files=files)
    manifest = {'schemaVersion': 3, 'installationMethod': 'source-build',
                'generatedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                'components': components, 'assets': [],
                'installationComplete': set(REQUIRED_BY_COMPONENT).issubset(components)}
    # Keep the public version fields used by the engine inspector and CLI.
    for key, value in components.items():
        manifest[key] = {k: v for k, v in value.items() if k != 'files'}
    paths = [p for p in sorted(staging.rglob('*')) if p.is_file() and not p.is_symlink() and p.name != 'manifest.json']
    for index, p in enumerate(paths, 1):
        manifest['assets'].append({'path': str(p.relative_to(staging)), 'bytes': p.stat().st_size, 'sha256': digest(p)})
        event('verify', '', 86 + 8 * index / max(1, len(paths)))
    return manifest


def verify_runtime(root, manifest):
    components = components_of(manifest)
    required = [p for key in components for p in REQUIRED_BY_COMPONENT[key]] if components else REQUIRED
    for name in required:
        path = root / name
        if not path.is_file() or path.stat().st_size == 0:
            raise SetupError(f'Built engine is incomplete: {name}')
    for asset in manifest['assets']:
        path = root / asset['path']
        if not path.is_file() or digest(path) != asset['sha256']:
            raise SetupError(f'Built engine checksum failed: {asset["path"]}')
    for name in ['Wine/bin/wine', 'Wine/bin/wineserver', 'MetalGoose/bin/metalgoose-backend']:
        if name in required and not os.access(root / name, os.X_OK):
            raise SetupError(f'Built executable is not executable: {name}')

def install(app, staging, manifest, entitlements):
    destination = app / 'Contents/Resources/Engines'
    previous = app.parent / ('.' + app.name + '-Engines-previous')
    if previous.exists():
        raise SetupError(f'A previous installation needs recovery: {previous}')
    had_previous = destination.exists()
    if had_previous:
        destination.rename(previous)
    try:
        staging.rename(destination)
        run(['codesign', '--force', '--sign', '-', '--entitlements', entitlements, app], capture=True)
        run(['codesign', '--verify', '--deep', '--strict', app], capture=True)
    except BaseException:
        if destination.exists():
            destination.rename(staging)
        if had_previous:
            previous.rename(destination)
        run(['codesign', '--force', '--sign', '-', '--entitlements', entitlements, app], capture=True)
        raise
    if previous.exists():
        shutil.rmtree(previous)


def main():
    global COMPONENT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--component', choices=list(REQUIRED_BY_COMPONENT), required=True)
    parser.add_argument('--sources-root', type=Path, default=Path.home() / 'Downloads/Github', help=argparse.SUPPRESS)
    parser.add_argument('--cache-root', type=Path, default=Path.home() / 'Library/Caches/GooseHUB')
    parser.add_argument('--lockfile', type=Path)
    parser.add_argument('--local-sources', action='store_true', help='Build existing developer working trees without fetching')
    parser.add_argument('--jobs', type=int, default=min(os.cpu_count() or 4, 8))
    args = parser.parse_args()
    COMPONENT = args.component
    app, cache = args.app.resolve(), args.cache_root.expanduser().resolve()
    source_root = args.sources_root.expanduser().resolve()
    support = Path(__file__).resolve().parent
    if not (support / 'Wine.entitlements').is_file():
        support = support.parent / 'Resources'
    spec = json.loads((args.lockfile or support / 'engine-lock.json').read_text())
    if spec.get('schemaVersion') != 2 or app.suffix != '.app' or not (app / 'Contents/MacOS/GooseHUB').is_file():
        raise SetupError('Invalid app bundle or source manifest.')
    resources = app / 'Contents/Resources'
    if not os.access(resources, os.W_OK):
        raise SetupError('Move GooseHUB to a writable folder and retry.')
    source_root.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    logs = cache / 'Logs/Install'
    logs.mkdir(parents=True, exist_ok=True)
    sys.stdout = BuildLog(sys.stdout, logs / (COMPONENT + '.log'))
    with (cache / 'engine-install.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as ex:
            raise SetupError('Another component is being installed.') from ex
        build = cache / 'Build'
        build.mkdir(exist_ok=True)
        installed = resources / 'Engines'
        if COMPONENT == 'dxmt':
            previous = components_of(read_manifest(installed))
            if previous.get('wine', {}).get('commit') != spec['repositories']['wine']['revision']:
                raise SetupError('Install Wine first.')
            if not (build / 'Wine/build/Makefile').is_file():
                raise SetupError('Wine build cache is missing. Reinstall Wine first.')
        env, prefix = tools(cache, spec['toolchain'], COMPONENT)
        event('sources', '', 8)
        selected = spec['repositories'][COMPONENT]
        source = fetch_repository(selected, source_root, local=args.local_sources)
        install_root = None
        if COMPONENT == 'wine':
            install_root = build_wine(source, build / 'Wine/build', env, args.jobs, support / 'Wine.entitlements')
        elif COMPONENT == 'fex':
            build_fex(source, build / 'FEX', env, args.jobs)
        elif COMPONENT == 'dxmt':
            build_dxmt(source, build / 'DXMT', build / 'Wine/build', env, prefix, args.jobs)
        else:
            run([sys.executable, source / 'Service/build.py', '--output', build / 'MetalGoose'],
                env=env, progress=(18, 78))
        # Transaction staging stays outside the signed app bundle.
        with tempfile.TemporaryDirectory(prefix='.goosehub-install-', dir=app.parent) as temporary:
            package = Path(temporary) / 'Package'
            package.mkdir()
            stage_component(COMPONENT, source, build, package, prefix, env, support, install_root)
            record = {'version': selected['version'], 'repository': selected['url'],
                      'commit': git(source, 'rev-parse', 'HEAD')}
            if COMPONENT == 'wine':
                record['stockDirect3D'] = True
            staging = Path(temporary) / 'Engines'
            manifest = merge_component(installed, package, staging, COMPONENT, record)
            verify_runtime(staging, manifest)
            (staging / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
            event('verify', '', 96)
            install(app, staging, manifest, support / 'GooseHUB.entitlements')
        event('complete', '', 100)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    try:
        main()
    except (SetupError, OSError, ValueError, subprocess.SubprocessError) as error:
        event('failed', str(error))
        sys.exit(1)
