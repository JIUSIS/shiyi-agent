#!/usr/bin/env python3
"""把手机定制的 Termux 环境（python/proot/termux-apt 等）重打包成 bootstrap zip。
- 条目相对 usr（bin/、lib/...），与官方 bootstrap 一致
- symlink 收集进 SYMLINKS.txt（old←new），供原生解压建链
- 硬编码的 v5 路径规范化为官方 /data/data/com.termux，部署时自动适配
- termux-apt 重写为动态路径（不依赖安装目录）
"""
import tarfile
import zipfile
import os

TAR = 'termux_usr.tgz'
OUT = 'bootstrap-custom.zip'
OLD_V5 = b'/data/user/0/com.shiyi.agent/files/termux_v5'
OLD_V4 = b'/data/user/0/com.shiyi.agent/files/termux_v4'

TERMUX_APT = '''#!/data/data/com.termux/files/usr/bin/sh
# termux-apt: run apt/pkg through proot (dynamic prefix resolution)
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
# 脚本位于 $PREFIX/bin/termux-apt，PREFIX 的上级目录即环境根（proot -r 根）。
ROOTFS=$(dirname "$(dirname "$(dirname "$SELF")")")
mkdir -p "$ROOTFS/tmp" "$ROOTFS/cache" "$ROOTFS/usr/tmp"
export LD_LIBRARY_PATH=$ROOTFS/usr/lib
export PROOT_TMP_DIR=$ROOTFS/tmp
export PROOT_LOADER=$ROOTFS/usr/libexec/proot/loader
ARGS="-r $ROOTFS -b /system:/system -b /vendor:/vendor -b /data:/data -b /dev:/dev -b /proc:/proc -b /sys:/sys -b /apex:/apex -b $ROOTFS:/data/data/com.termux/files -b $ROOTFS/cache:/data/data/com.termux/cache"
if [ "$1" = "apt" ] || [ "$1" = "pkg" ]; then
    CMD="$1"; shift
    exec "$ROOTFS/usr/bin/proot" $ARGS -w / /usr/bin/$CMD "$@"
else
    exec "$ROOTFS/usr/bin/proot" $ARGS -w / /usr/bin/apt "$@"
fi
'''.encode('utf-8')

def norm(data: bytes) -> bytes:
    for old in (OLD_V5, OLD_V4):
        if old in data:
            data = data.replace(old, b'/data/data/com.termux')
    return data

tf = tarfile.open(TAR, 'r:gz')
symlinks = []          # (target, link_path)
file_entries = []      # (rel_path, data)

for m in tf.getmembers():
    name = m.name.replace('\\', '/')
    if not name.startswith('termux_v5/usr/'):
        continue
    rel = name[len('termux_v5/usr/'):]
    if rel == '':
        continue
    if m.isdir():
        file_entries.append((rel + '/', b''))
    elif m.issym():
        target = m.linkname.replace('\\', '/')
        symlinks.append((target, rel))
    elif m.isfile():
        data = tf.extractfile(m).read()
        if rel == 'bin/termux-apt':
            data = TERMUX_APT
        else:
            data = norm(data)
        file_entries.append((rel, data))
tf.close()

# 写 zip：SYMLINKS.txt 第一个条目
symlink_content = ''.join(f'{t}←{n}\n' for t, n in symlinks).encode('utf-8')
with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
    zf.writestr('SYMLINKS.txt', symlink_content)
    for rel, data in file_entries:
        zf.writestr(rel, data)

sz = os.path.getsize(OUT)
print(f'打包完成: {OUT} {sz/1024/1024:.1f}MB, 文件 {len(file_entries)}, symlink {len(symlinks)}')
print('termux-apt shebang 检查:')
import zipfile as z
with z.ZipFile(OUT) as f:
    print('  ', f.read('bin/termux-apt')[:60])
    print('  SYMLINKS.txt 前3行:', f.read('SYMLINKS.txt')[:80])
