#!/usr/bin/env python3
"""Fetch the Adrenalin source repositories, build, verify and install one runtime."""
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


class SetupError(RuntimeError):
    pass


def event(phase, message):
    print(EVENT_PREFIX + json.dumps({'phase': phase, 'message': message}), flush=True)


def run(args, *, cwd=None, env=None, capture=False):
    global ACTIVE
    args = [str(a) for a in args]
    print('+ ' + ' '.join(args), flush=True)
    child = subprocess.Popen(args, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, errors='replace', start_new_session=True)
    ACTIVE = child
    output = []
    try:
        for line in child.stdout:
            if capture:
                output.append(line)
            else:
                print(line, end='', flush=True)
        code = child.wait()
        if code:
            detail = ''.join(output)[-2000:] if capture else ''
            raise SetupError(f'{Path(args[0]).name} exited with {code}. {detail}')
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
    raise SetupError('Installation cancelled. Existing source files and installed engines were retained.')


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def git(path, *args, capture=True):
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    return run(['git', '-C', path, *args], env=env, capture=capture).strip()


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
    if revision == 'pending':
        raise SetupError(f'The {name} source revision has not been published.')
    if not path.exists():
        # A failed clone is owned by this invocation; existing directories are never removed.
        temporary = Path(tempfile.mkdtemp(prefix=f'.{name}-', dir=root))
        try:
            git(temporary, 'init', capture=False)
            git(temporary, 'remote', 'add', 'origin', spec['url'])
            git(temporary, 'fetch', '--depth=1', '--no-tags', 'origin', revision, capture=False)
            git(temporary, 'checkout', '--detach', 'FETCH_HEAD')
            temporary.rename(path)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
    else:
        if not (path / '.git').exists():
            raise SetupError(f'{path} already exists and is not a Git repository. Choose another source folder.')
        origin = git(path, 'remote', 'get-url', 'origin')
        if origin.removesuffix('.git').lower() != spec['url'].removesuffix('.git').lower():
            raise SetupError(f'{path} belongs to a different repository. Choose another source folder.')
        if git(path, 'status', '--porcelain', '--untracked-files=normal', '--ignore-submodules=untracked'):
            raise SetupError(f'{path} has uncommitted changes. Commit them or choose another source folder; nothing was overwritten.')
        git(path, 'fetch', '--no-tags', 'origin', revision, capture=False)
        wanted = git(path, 'rev-parse', 'FETCH_HEAD^{commit}')
        current = git(path, 'rev-parse', 'HEAD')
        if current != wanted:
            # Do not detach or reset a user's development checkout.
            git(path, 'merge', '--ff-only', wanted, capture=False)
        if git(path, 'rev-parse', 'HEAD') != wanted:
            raise SetupError(f'{path} is ahead of the required revision. Choose another source folder; local commits were retained.')
    # FEX test-bin submodules are not build dependencies and are not downloaded.
    if name == 'fex-adrenalin-edition':
        modules = ['External/vixl', 'External/fmt', 'External/xxhash', 'External/Catch2',
                   'External/jemalloc_glibc', 'External/tracy', 'External/range-v3',
                   'External/zydis', 'External/unordered_dense', 'External/rpmalloc',
                   'Source/Common/cpp-optparse', 'External/Vulkan-Headers', 'External/drm-headers']
        git(path, 'submodule', 'update', '--init', '--recursive', '--', *modules, capture=False)
    elif name == 'dxmt-adrenalin-edition':
        git(path, 'submodule', 'update', '--init', '--recursive', capture=False)
    return path


def tools(cache, spec):
    event('tools', 'Checking build tools')
    if sys.platform != 'darwin' or os.uname().machine != 'arm64':
        raise SetupError('Engine source builds require an Apple Silicon Mac.')
    run(['xcrun', '--find', 'clang'], capture=True)
    run(['xcrun', '--find', 'metal'], capture=True)
    brew = shutil.which('brew') or '/opt/homebrew/bin/brew'
    if not Path(brew).is_file():
        raise SetupError('Install Homebrew and Xcode with the Metal toolchain, then retry.')
    prefix = Path(run([brew, '--prefix'], capture=True).strip())
    formulae = ['bison', 'cmake', 'ninja', 'meson', 'pkgconf', 'ccache', 'llvm', 'lld', 'mingw-w64',
                'freetype', 'gnutls', 'sdl2-compat', 'sdl3', 'vulkan-loader', 'molten-vk',
                'gstreamer', 'dbus', 'cups', 'samba', 'unixodbc']
    installed = set(run([brew, 'list', '--formula'], capture=True).splitlines())
    missing = [f for f in formulae if f not in installed]
    if missing:
        event('tools', 'Installing build and media dependencies')
        run([brew, 'install', *missing], env=dict(os.environ, HOMEBREW_NO_AUTO_UPDATE='1'))
    compiler_root = cache / 'Toolchains' / spec['directory']
    if not (compiler_root / 'bin/arm64ec-w64-mingw32-clang').is_file():
        if not re.fullmatch('[a-f0-9]{64}', spec['sha256']):
            raise SetupError('The compiler download checksum is missing.')
        event('tools', 'Downloading the compiler toolchain')
        compiler_root.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=compiler_root.parent) as temporary:
            folder = Path(temporary)
            archive = folder / 'compiler.tar.xz'
            with urllib.request.urlopen(spec['url'], timeout=60) as response, archive.open('wb') as output:
                shutil.copyfileobj(response, output)
            if digest(archive) != spec['sha256']:
                raise SetupError('The compiler archive checksum does not match.')
            with tarfile.open(archive) as tar:
                tar.extractall(folder, filter='data')
            extracted = folder / spec['directory']
            if not (extracted / 'bin/arm64ec-w64-mingw32-clang').is_file():
                raise SetupError('The compiler archive is incomplete.')
            extracted.rename(compiler_root)
    env = dict(os.environ)
    env['PATH'] = ':'.join(str(p) for p in [compiler_root / 'bin', prefix / 'opt/llvm/bin',
                       prefix / 'opt/lld/bin', prefix / 'opt/bison/bin', prefix / 'bin']) + ':/usr/bin:/bin:/usr/sbin:/sbin'
    env['PKG_CONFIG_PATH'] = f'{prefix}/lib/pkgconfig:{prefix}/share/pkgconfig'
    env['GOOSE_LLVM_ROOT'] = str(prefix / 'opt/llvm')
    return env, prefix


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
    run(['make', 'depend'], cwd=build, env=env)
    run(['make', f'-j{jobs}'], cwd=build, env=env)
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
            run(['make', f'-j{jobs}', 'i386_CFLAGS=-g -O2 -DWINE_OPENGL_BATCHING',
                 'dlls/opengl32/i386-windows/opengl32.dll'], cwd=build, env=env)
            shutil.copy2(build / 'dlls/opengl32/i386-windows/opengl32.dll', overlay / 'opengl32.dll')
        finally:
            for p in objects:
                p.unlink(missing_ok=True)
        run(['make', f'-j{jobs}', 'dlls/opengl32/i386-windows/opengl32.dll'], cwd=build, env=env)
        stamp.write_text(source_key + '\n')
    install = build.parent / 'install'
    run(['make', 'install-lib', f'DESTDIR={install}'], cwd=build, env=env)
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
        run(['cmake', '--build', output, '--target', target, '--parallel', str(jobs)], env=env)
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
        run(['meson', 'compile', '-C', output, '-j', str(jobs)], env=env)
        run(['meson', 'install', '-C', output, '--no-rebuild', '--destdir', build / f'{name}-install'], env=env)


def copy_tree(source, destination):
    shutil.copytree(source, destination, symlinks=True)


def macho(path):
    if not path.is_file() or path.is_symlink():
        return False
    with path.open('rb') as f:
        return f.read(4) in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe')


class NativeLibraries:
    def __init__(self, root, prefix, env, entitlements):
        self.root, self.prefix, self.env, self.entitlements = root, prefix, env, entitlements
        self.dependencies = root / 'Dependencies/arm64'
        self.dependencies.mkdir(parents=True)
        self.seen = set()
        self.origins = {}

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
            if internal.is_file():
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


def stage_runtime(sources, build, install, root, prefix, env, support, jobs):
    event('install', 'Installing the built engines')
    copy_tree(install, root / 'Wine')
    dlls = root / 'Wine/lib/wine'
    for arch, original in [('arm64ec', 'aarch64-windows'), ('x86', 'i386-windows')]:
        destination = root / f'DXMT/{arch}'
        destination.mkdir(parents=True)
        for p in (build / f'DXMT/{arch}-install' / original).glob('*.dll'):
            shutil.copy2(p, destination / p.name)
            if p.name != 'winemetal.dll':
                with (destination / p.name).open('r+b') as f:
                    f.seek(64)
                    if f.read(16) == b'Wine builtin DLL':
                        f.seek(64)
                        f.write(b'\0' * 17)
        shutil.copy2(destination / 'winemetal.dll', dlls / original / 'winemetal.dll')
    unix = dlls / 'aarch64-unix'
    shutil.copy2(build / 'DXMT/arm64ec-install/aarch64-unix/winemetal.so', unix / 'winemetal.so')
    for guest, name, alias in [('arm64ec', 'libarm64ecfex.dll', 'xtajit64.dll'),
                               ('wow64', 'libwow64fex.dll', 'xtajit.dll')]:
        source = build / f'FEX/{guest}/Bin' / name
        shutil.copy2(source, dlls / 'aarch64-windows' / name)
        shutil.copy2(source, dlls / 'aarch64-windows' / alias)
        shutil.copy2(build / 'FEX/unix' / name.replace('.dll', '.so'), unix / name.replace('.dll', '.so'))
    overlay = root / 'LegacyOpenGL'
    (overlay / 'i386-windows').mkdir(parents=True)
    (overlay / 'aarch64-unix').mkdir()
    shutil.copy2(build / 'Wine/legacy-opengl/i386-windows/opengl32.dll', overlay / 'i386-windows/opengl32.dll')
    shutil.copy2(unix / 'opengl32.so', overlay / 'aarch64-unix/opengl32.so')
    (root / 'Config').mkdir()
    shutil.copy2(sources['dxmt'] / 'dxmt.conf', root / 'Config/dxmt.conf')
    media = root / 'Media'
    (media / 'gstreamer-1.0').mkdir(parents=True)
    gst = prefix / 'opt/gstreamer'
    plugins = ['coreelements', 'app', 'playback', 'audioconvert', 'audioresample',
               'typefindfunctions', 'videoconvertscale', 'videofilter', 'volume',
               'isomp4', 'matroska', 'ogg', 'wavparse', 'avi', 'id3demux', 'asf',
               'mpegpsdemux', 'mpegtsdemux', 'libav', 'audioparsers', 'videoparsersbad']
    for name in plugins:
        p = gst / 'lib/gstreamer-1.0' / f'libgst{name}.dylib'
        if not p.is_file():
            raise SetupError(f'The installed GStreamer is missing {p.name}')
        shutil.copy2(p.resolve(), media / 'gstreamer-1.0' / p.name)
    scanner = gst / 'libexec/gstreamer-1.0/gst-plugin-scanner'
    (media / 'bin').mkdir()
    shutil.copy2(scanner.resolve(), media / 'bin/gst-plugin-scanner')
    libraries = NativeLibraries(root, prefix, env, support / 'Wine.entitlements')
    config = (build / 'Wine/build/include/config.h').read_text()
    sonames = []
    for name in re.findall(r'^#define SONAME_\w+ "([^"]+)"', config, re.M):
        path = Path(name) if name.startswith('/') else prefix / 'lib' / name
        libraries.library(path)
        if name.startswith('/'):
            sonames.append((name.encode() + b'\0', ('@rpath/' + path.name).encode() + b'\0'))
    for name in ['libSDL3.dylib', 'libMoltenVK.dylib']:
        libraries.library(prefix / 'lib' / name)
    (root / 'Vulkan/icd.d').mkdir(parents=True)
    (root / 'Vulkan/icd.d/MoltenVK_icd.json').write_text(json.dumps({
        'file_format_version': '1.0.0', 'ICD': {
            'library_path': '../../Dependencies/arm64/libMoltenVK.dylib', 'api_version': '1.4.0'}}) + '\n')
    event('metalgoose', 'Building MetalGoose')
    backend = sources['goosehub'] / 'Sources/MetalGooseBackend'
    metal = root / 'MetalGoose/bin'
    metal.mkdir(parents=True)
    run(['xcrun', 'swiftc', '-O', '-wmo', '-parse-as-library', '-swift-version', '6',
         '-target', 'arm64-apple-macos27.0', '-import-objc-header', backend / 'Shaders/ShaderTypes.h',
         '-o', metal / 'metalgoose-backend', *sorted(backend.rglob('*.swift'))], env=env)
    air = build / 'MetalGoose'
    air.mkdir(exist_ok=True)
    objects = []
    for shader in sorted((backend / 'Shaders').glob('*.metal')):
        obj = air / (shader.stem + '.air')
        run(['xcrun', 'metal', '-c', '-target', 'air64-apple-macos27.0', '-std=metal4.1', '-o', obj, shader], env=env)
        objects.append(obj)
    run(['xcrun', 'metallib', '-o', metal / 'default.metallib', *objects], env=env)
    for p in sorted(root.rglob('*')):
        if macho(p):
            libraries.relink(p, sonames if root / 'Wine' in p.parents else ())
    licenses = root / 'Licenses'
    for key, filename in [('wine', 'COPYING.LIB'), ('fex', 'LICENSE'), ('dxmt', 'LICENSE'), ('goosehub', 'LICENSE')]:
        target = licenses / key
        target.mkdir(parents=True)
        if (sources[key] / filename).is_file():
            shutil.copy2(sources[key] / filename, target / filename)
    # Include each external dependency's installed license material.
    for path in libraries.dependencies.iterdir():
        origin = prefix / 'lib' / path.name
        if origin.is_file():
            real = origin.resolve()
            parts = real.parts
            if 'Cellar' not in parts:
                continue
            index = parts.index('Cellar')
            keg = Path(*parts[:index + 3])
            for item in [*keg.glob('LICENSE*'), *keg.glob('COPYING*')]:
                if item.is_file():
                    target = licenses / 'Dependencies' / keg.parent.name / keg.name
                    target.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(item, target / item.name)


REQUIRED = ['Wine/bin/wine', 'Wine/bin/wineserver', 'Wine/share/wine/wine.inf',
            'Wine/lib/wine/aarch64-windows/xtajit64.dll', 'Wine/lib/wine/aarch64-windows/xtajit.dll',
            'Wine/lib/wine/aarch64-unix/libarm64ecfex.so', 'Wine/lib/wine/aarch64-unix/libwow64fex.so',
            'Wine/lib/wine/aarch64-unix/winemetal.so', 'DXMT/arm64ec/d3d9.dll',
            'DXMT/arm64ec/d3d11.dll', 'DXMT/arm64ec/d3d12.dll', 'DXMT/arm64ec/dxgi.dll',
            'DXMT/x86/d3d9.dll', 'DXMT/x86/d3d11.dll', 'DXMT/x86/d3d12.dll', 'DXMT/x86/dxgi.dll',
            'MetalGoose/bin/metalgoose-backend', 'MetalGoose/bin/default.metallib',
            'Vulkan/icd.d/MoltenVK_icd.json', 'Dependencies/arm64/libMoltenVK.dylib',
            'Media/bin/gst-plugin-scanner', 'LegacyOpenGL/i386-windows/opengl32.dll']


def verify_runtime(root, manifest):
    for name in REQUIRED:
        path = root / name
        if not path.is_file() or path.stat().st_size == 0:
            raise SetupError(f'Built engine is incomplete: {name}')
    for asset in manifest['assets']:
        path = root / asset['path']
        if not path.is_file() or digest(path) != asset['sha256']:
            raise SetupError(f'Built engine checksum failed: {asset["path"]}')
    for name in ['Wine/bin/wine', 'Wine/bin/wineserver', 'MetalGoose/bin/metalgoose-backend']:
        if not os.access(root / name, os.X_OK):
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--sources-root', type=Path, default=Path.home() / 'Downloads/Github')
    parser.add_argument('--cache-root', type=Path, default=Path.home() / 'Library/Caches/GooseHUB')
    parser.add_argument('--lockfile', type=Path)
    parser.add_argument('--local-sources', action='store_true', help='Developer-only: build existing working trees without fetching')
    parser.add_argument('--jobs', type=int, default=min(os.cpu_count() or 4, 8))
    args = parser.parse_args()
    app, cache, source_root = args.app.resolve(), args.cache_root.expanduser().resolve(), args.sources_root.expanduser().resolve()
    support = Path(__file__).resolve().parent
    if not (support / 'Wine.entitlements').is_file():
        support = support.parent / 'Resources'
    lockfile = args.lockfile or support / 'engine-lock.json'
    spec = json.loads(lockfile.read_text())
    if spec.get('schemaVersion') != 1 or app.suffix != '.app' or not (app / 'Contents/MacOS/GooseHUB').is_file():
        raise SetupError('Invalid app bundle or source manifest.')
    resources = app / 'Contents/Resources'
    if not os.access(resources, os.W_OK):
        raise SetupError('GooseHUB cannot write to this app. Move it to your user Applications folder and retry.')
    source_root.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / 'engine-install.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as ex:
            raise SetupError('Another engine installation is running.') from ex
        env, prefix = tools(cache, spec['toolchain'])
        event('sources', 'Fetching the Adrenalin source repositories')
        sources = {key: fetch_repository(value, source_root, local=args.local_sources)
                   for key, value in spec['repositories'].items()}
        build = cache / 'Build'
        build.mkdir(exist_ok=True)
        install_root = build_wine(sources['wine'], build / 'Wine/build', env, args.jobs, support / 'Wine.entitlements')
        build_fex(sources['fex'], build / 'FEX', env, args.jobs)
        build_dxmt(sources['dxmt'], build / 'DXMT', build / 'Wine/build', env, prefix, args.jobs)
        with tempfile.TemporaryDirectory(prefix='.Engines-install-', dir=resources) as temporary:
            staging = Path(temporary) / 'Engines'
            staging.mkdir()
            stage_runtime(sources, build, install_root, staging, prefix, env, support, args.jobs)
            event('verify', 'Verifying the built engines')
            manifest = {'schemaVersion': 2, 'installationComplete': True, 'installationMethod': 'source-build',
                        'generatedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'assets': []}
            for key, path in sources.items():
                manifest[key] = {'version': f'{key.upper()} Adrenalin Edition', 'repository': spec['repositories'][key]['url'],
                                 'commit': git(path, 'rev-parse', 'HEAD')}
            provenance = json.loads((sources['goosehub'] / 'Resources/engine-sources.json').read_text())
            manifest['wine']['version'] = provenance['wine']['selectedVersion']
            manifest['dxmt']['version'] = provenance['dxmt']['version']
            manifest['fex']['version'] = 'FEX-2610 Adrenalin Edition'
            manifest['wine']['stockDirect3D'] = True
            for p in sorted(staging.rglob('*')):
                if p.is_file() and not p.is_symlink():
                    manifest['assets'].append({'path': str(p.relative_to(staging)), 'bytes': p.stat().st_size,
                                               'sha256': digest(p)})
            verify_runtime(staging, manifest)
            (staging / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
            install(app, staging, manifest, support / 'GooseHUB.entitlements')
        event('complete', 'All engines are installed')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    try:
        main()
    except (SetupError, OSError, ValueError, subprocess.SubprocessError) as error:
        event('failed', str(error))
        sys.exit(1)
