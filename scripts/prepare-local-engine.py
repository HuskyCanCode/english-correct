#!/usr/bin/env python3
"""Fetch the pinned upstream Apple Silicon engine; never fetch model weights."""
import hashlib, pathlib, shutil, subprocess, sys, tarfile
root = pathlib.Path(__file__).resolve().parent.parent
version = 'b11146'
digest = '1ad3f9eff80edb9dbef4259ad564d1720612ef7eea48fa4afed0e54f5f3d5711'
cache = root / 'dist' / 'engine-cache'
cache.mkdir(parents=True, exist_ok=True)
archive = cache / f'llama-{version}-bin-macos-arm64.tar.gz'
if not archive.exists():
    subprocess.run(['curl', '--fail', '--location', '--proto', '=https', '--tlsv1.2', '--output', str(archive), f'https://github.com/ggml-org/llama.cpp/releases/download/{version}/{archive.name}'], check=True)
if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
    sys.exit('Engine archive checksum failed. Remove the cached archive and retry.')
destination = pathlib.Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
names = ['llama-server', 'libllama-server-impl.dylib', 'libllama-common.0.dylib', 'libmtmd.0.dylib', 'libllama.0.dylib', 'libggml.0.dylib', 'libggml-cpu.0.dylib', 'libggml-blas.0.dylib', 'libggml-metal.0.dylib', 'libggml-rpc.0.dylib', 'libggml-base.0.dylib']
with tarfile.open(archive) as tar:
    for name in names:
        member = tar.getmember(f'llama-{version}/{name}')
        # Archive symlinks are resolved inside this verified tarball, then copied
        # as regular files. No tar paths or links are extracted to the filesystem.
        while member.issym():
            member = tar.getmember(f'llama-{version}/{member.linkname}')
        if not member.isfile(): sys.exit('Unexpected engine archive member')
        with tar.extractfile(member) as source, (destination/name).open('wb') as output:
            shutil.copyfileobj(source, output)
        (destination/name).chmod(0o755)
print(f'Prepared llama.cpp {version}: {sum(p.stat().st_size for p in destination.iterdir()) / 1_000_000:.1f} MB')
