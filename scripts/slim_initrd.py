#!/usr/bin/env python3
"""Cut the dArkOS uInitrd down to what mounting an ext4 root needs.

    slim_initrd.py <uInitrd> [--rootfs DIR] [-o OUTPUT]

The stock initramfs carries udev (13 MB hwdb, libsystemd-shared, libcrypto),
btrfs tools and 4.4 kernel modules. The root is a plain /dev/mmcblk0p2 on
drivers built into every kernel the image boots, so none of that runs for a
reason: wait_for_udev does nothing without udevadm, and the stock scripts
wait for the root device on their own.

--rootfs adds e2fsck from that root when the initramfs has no fsck.ext4,
and fsck.f2fs when the root has it: the initramfs checks the root with
fsck -t <type>, and without the checker the fsck wrapper prints "not found"
on the console and the root goes unchecked. An initramfs that is already
slim is only given the missing checkers.
Output stays one gzip member in a legacy uImage: the Rockchip 4.4 kernel
cannot unpack zstd and stops after the first compressed member. Works on
the cpio stream, so it needs neither root nor an arm64 chroot. Aborts if a
kept binary would miss a library.
"""
import argparse
import gzip
import os
import re
import stat
import struct
import sys
import zlib

LIBDIR = "usr/lib/aarch64-linux-gnu/"
UIMAGE_MAGIC = 0x27051956
MAX_SIZE = 0x01f00000 - 0x01100000  # boot.ini: initrd load address to dtb

DROP = re.compile(
    r"usr/lib/udev(/|$)|etc/udev(/|$)|usr/lib/modules(/|$)|lib/modules(/|$)"
    r"|usr/lib/modprobe\.d(/|$)|etc/modprobe\.d(/|$)|usr/lib/systemd(/|$)"
    r"|usr/lib/aarch64-linux-gnu/systemd(/|$)"
    r"|usr/bin/(udevadm|kmod|btrfs|nfsmount|ipconfig)$"
    r"|usr/sbin/(modprobe|rmmod|fsck\.btrfs)$"
    r"|scripts/init-top/udev$|scripts/local-premount/(btrfs|resume)$")
ORDER_DROP = re.compile(r"/scripts/(init-top/udev|local-premount/(btrfs|resume)) ")


class Entry:
    __slots__ = ("name", "mode", "mtime", "data", "group", "rdev")


def read_cpio(blob):
    """All newc archives in blob. Hardlinked names share one data object."""
    entries, off, archive, links = [], 0, 0, {}
    while off + 110 <= len(blob):
        if blob[off:off + 6] != b"070701":
            if blob[off:].strip(b"\0"):
                sys.exit(f"bad cpio header at {off}")
            break
        f = [int(blob[off + 6 + 8 * i:off + 14 + 8 * i], 16) for i in range(13)]
        ino, mode, nlink, mtime, size, namesize = f[0], f[1], f[4], f[5], f[6], f[11]
        name_start = off + 110
        name = blob[name_start:name_start + namesize - 1].decode()
        data_start = (name_start + namesize + 3) & ~3
        data = blob[data_start:data_start + size]
        off = (data_start + size + 3) & ~3
        if name == "TRAILER!!!":
            archive += 1
            while off < len(blob) and blob[off] == 0:
                off += 1
            off &= ~3
            continue
        e = Entry()
        e.name, e.mode, e.mtime, e.data = name.lstrip("./") or ".", mode, mtime, data
        e.rdev = (f[9], f[10])
        e.group = None
        if stat.S_ISREG(mode) and nlink > 1:
            e.group = links.setdefault((archive, ino), [])
            e.group.append(e)
        entries.append(e)
    for group in links.values():
        data = next((x.data for x in group if x.data), b"")
        for x in group:
            x.data = data
    return entries


def write_cpio(entries):
    out, ino, written, nlinks = [], 0, {}, {}
    for e in entries:
        if e.group is not None:
            nlinks[id(e.group)] = nlinks.get(id(e.group), 0) + 1
    seen = {}

    def record(name, mode, nlink, mtime, data, this_ino, rdev=(0, 0)):
        raw = name.encode() + b"\0"
        hdr = "070701" + "".join("%08X" % v for v in (
            this_ino, mode, 0, 0, nlink, mtime, len(data), 0, 0,
            rdev[0], rdev[1], len(raw), 0))
        out.append(hdr.encode() + raw + b"\0" * (-(110 + len(raw)) % 4))
        out.append(data + b"\0" * (-len(data) % 4))

    for e in entries:
        nlink = 2 if stat.S_ISDIR(e.mode) else 1
        data = e.data
        if e.group is not None:
            key = id(e.group)
            if key not in written:
                ino += 1
                written[key] = ino
            this_ino, nlink = written[key], nlinks[key]
            seen[key] = seen.get(key, 0) + 1
            if seen[key] != nlink:  # newc: the data goes with the last name
                data = b""
        else:
            ino += 1
            this_ino = ino
        record(e.name, e.mode, nlink, e.mtime, data, this_ino, e.rdev)
    record("TRAILER!!!", 0, 1, 0, b"", 0)
    return b"".join(out)


def needed(elf):
    """DT_NEEDED names of a little-endian ELF64, or None if not one."""
    if elf[:6] != b"\x7fELF\x02\x01":
        return None
    phoff, phentsize, phnum = (struct.unpack_from("<Q", elf, 32)[0],
                               struct.unpack_from("<H", elf, 54)[0],
                               struct.unpack_from("<H", elf, 56)[0])
    loads, dyn = [], None
    for i in range(phnum):
        p = phoff + i * phentsize
        ptype = struct.unpack_from("<I", elf, p)[0]
        offset, vaddr = struct.unpack_from("<QQ", elf, p + 8)
        filesz = struct.unpack_from("<Q", elf, p + 32)[0]
        if ptype == 1:
            loads.append((vaddr, offset, filesz))
        elif ptype == 2:
            dyn = (offset, filesz)
    if not dyn:
        return []

    def v2o(addr):
        for vaddr, offset, filesz in loads:
            if vaddr <= addr < vaddr + filesz:
                return addr - vaddr + offset
        sys.exit("dynamic string table outside PT_LOAD")

    strtab, names = None, []
    for off in range(dyn[0], dyn[0] + dyn[1], 16):
        tag, val = struct.unpack_from("<qQ", elf, off)
        if tag == 0:
            break
        if tag == 5:
            strtab = v2o(val)
        elif tag == 1:
            names.append(val)
    out = []
    for n in names:
        start = strtab + n
        out.append(elf[start:elf.index(b"\0", start)].decode())
    return out


def add_binary(entries, root, name, links=()):
    """Add a binary from root, symlinks to it, and any of its libraries the
    initramfs does not have."""
    have = {e.name for e in entries}
    def regular(name):
        path = os.path.realpath(os.path.join(root, name))
        e = Entry()
        e.name, e.mode, e.mtime, e.group, e.rdev = name, 0o100755, 0, None, (0, 0)
        with open(path, "rb") as f:
            e.data = f.read()
        return e
    binary = regular(name)
    entries.append(binary)
    for link_name in links:
        link = Entry()
        link.name, link.mode, link.mtime, link.group, link.rdev = (
            link_name, 0o120777, 0, None, (0, 0))
        link.data = os.path.basename(name).encode()
        entries.append(link)
    todo = list(needed(binary.data))
    while todo:
        lib = todo.pop()
        if LIBDIR + lib in have or "ld-linux" in lib:
            continue
        have.add(LIBDIR + lib)
        e = regular(LIBDIR + lib)
        entries.append(e)
        todo += needed(e.data) or []


def add_checkers(entries, root):
    """fsck.ext4 (e2fsck) if missing; fsck.f2fs if the root has it."""
    have = {e.name for e in entries}
    if "usr/sbin/fsck.ext4" not in have:
        add_binary(entries, root, "usr/sbin/e2fsck", ["usr/sbin/fsck.ext4"])
    if ("usr/sbin/fsck.f2fs" not in have
            and os.path.exists(os.path.join(root, "usr/sbin/fsck.f2fs"))):
        add_binary(entries, root, "usr/sbin/fsck.f2fs")


def f2fs_auto_fix(entries):
    """fsck.repair=yes makes the initramfs run fsck -y. fsck.f2fs -y checks
    the whole filesystem every boot (90 s on the SD card); -a checks only
    when the kernel marked it as needing a check."""
    functions = next(e for e in entries if e.name == "scripts/functions")
    text = functions.data.decode()
    patch = ('\tif [ "$TYPE" = f2fs ]; then\n'
             '\t\tfix="-a"\n'
             '\tfi\n\n')
    if patch in text:
        return
    anchor = '\tspinner=""\n'
    if text.count(anchor) != 1:
        sys.exit("scripts/functions: fsck options not found")
    functions.data = text.replace(anchor, patch + anchor).encode()


def f2fs_quiet_check(entries):
    """Like the ext4 shortcut in slim(): a root that fsck.f2fs -a finds clean
    is not checked again, and its report goes to the log only instead of
    filling the console at every boot. Anything else (forced check, errors)
    still goes through the normal, visible path."""
    functions = next(e for e in entries if e.name == "scripts/functions")
    text = functions.data.decode()
    shortcut = ('\tif [ -z "$force" ] && [ "$TYPE" = f2fs ] &&\n'
                '\t   fsck.f2fs -a "$DEV" >"$FSCK_LOGFILE" 2>&1; then\n'
                '\t\ttrue >"$FSCK_STAMPFILE"\n'
                '\t\treturn 0\n'
                '\tfi\n\n')
    if shortcut in text:
        return
    anchor = '\tif [ "${quiet}" = n ]\n\tthen\n\t\tlog_begin_msg "Will now check $NAME file system"\n'
    if text.count(anchor) != 1:
        sys.exit("scripts/functions: fsck call not found")
    functions.data = text.replace(anchor, shortcut + anchor).encode()


def is_slim(entries):
    local = next((e for e in entries if e.name == "scripts/local"), None)
    return local is not None and b"\t\t\tsleep 0.02\n" in local.data


def strip_udev_calls(text):
    return re.sub(r"^udevadm .*\n", "", text, flags=re.M)


def slim(entries):
    kept = [e for e in entries if not DROP.match(e.name)]
    by_name = {e.name: e for e in kept}

    # scripts: no udev, poll for the root device instead of sleeping 1 s
    for e in kept:
        if e.name.endswith("/ORDER"):
            lines = e.data.decode().splitlines(True)
            out = []
            for i, line in enumerate(lines):
                if ORDER_DROP.match(line):
                    continue
                if line.startswith("[ -e /conf/param.conf ]") and i and ORDER_DROP.match(lines[i - 1]):
                    continue
                out.append(line)
            e.data = "".join(out).encode()
    bottom = by_name["scripts/init-bottom/udev"]
    bottom.data = strip_udev_calls(bottom.data.decode()).encode()
    local = by_name["scripts/local"]
    text = local.data.decode()
    if "\t\t\tsleep 1\n" not in text:
        sys.exit("scripts/local: wait loop not found")
    local.data = text.replace("\t\t\tsleep 1\n", "\t\t\tsleep 0.02\n").encode()

    # a clean ext4 needs no read-write fsck; that first write access to the
    # card costs seconds. Only e2fsck's own "clean, ..." fast path counts: a
    # forced check or a dirty journal can exit 0 under -n and must still go
    # through the normal repair path.
    functions = by_name["scripts/functions"]
    text = functions.data.decode()
    anchor = '\tif [ "${quiet}" = n ]\n\tthen\n\t\tlog_begin_msg "Will now check $NAME file system"\n'
    if text.count(anchor) != 1:
        sys.exit("scripts/functions: fsck call not found")
    shortcut = ('\tif [ -z "$force" ] && [ "$TYPE" = ext4 ] &&\n'
                '\t   e2fsck -n "$DEV" >"$FSCK_LOGFILE" 2>&1 &&\n'
                '\t   grep -q ": clean, " "$FSCK_LOGFILE"; then\n'
                '\t\ttrue >"$FSCK_STAMPFILE"\n'
                '\t\treturn 0\n'
                '\tfi\n\n')
    functions.data = text.replace(anchor, shortcut + anchor).encode()

    # keep the libraries the remaining binaries reach
    def resolve(name):
        for _ in range(8):
            e = by_name.get(name)
            if e is None or not stat.S_ISLNK(e.mode):
                return e
            name = os.path.normpath(os.path.join(os.path.dirname(name), e.data.decode()))
        return None

    roots = [e for e in kept
             if stat.S_ISREG(e.mode) and not e.name.startswith(LIBDIR)
             and e.data[:4] == b"\x7fELF"]
    wanted, todo, done = {"ld-linux-aarch64.so.1"}, [], set()
    for e in {id(x.data): x for x in roots}.values():
        todo += needed(e.data) or []
    while todo:
        lib = todo.pop()
        if lib in done:
            continue
        done.add(lib)
        wanted.add(lib)
        if lib.startswith("klibc-"):
            if "usr/lib/" + lib not in by_name:
                sys.exit(f"missing {lib}")
            continue
        target = resolve(LIBDIR + lib)
        if target is None:
            sys.exit(f"missing library {lib}")
        todo += needed(target.data) or []

    keep_files = set()
    for lib in wanted:
        name = LIBDIR + lib
        while name in by_name:
            keep_files.add(name)
            e = by_name[name]
            if not stat.S_ISLNK(e.mode):
                break
            name = os.path.normpath(os.path.join(os.path.dirname(name), e.data.decode()))
    kept = [e for e in kept
            if not e.name.startswith(LIBDIR) or stat.S_ISDIR(e.mode)
            or e.name in keep_files]
    # no dangling symlinks into what was dropped
    names = {e.name for e in kept}
    kept = [e for e in kept if not stat.S_ISLNK(e.mode)
            or e.data.startswith(b"/") or os.path.normpath(
                os.path.join(os.path.dirname(e.name), e.data.decode())) in names]

    # /init runs as PID 1 and a failed "." ends it, which panics the kernel:
    # everything it and the ORDER files name has to be there
    names = {e.name for e in kept}
    sourced = re.findall(r"^\s*\. (/[\w./-]+)\s*$",
                         by_name["init"].data.decode(), flags=re.M)
    for e in kept:
        if e.name.endswith("/ORDER"):
            sourced += re.findall(r"^(/scripts/\S+) ", e.data.decode(), flags=re.M)
    for path in sourced:
        if path.lstrip("/") not in names:
            sys.exit(f"{path} is used at boot but was dropped")
    return kept


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("uinitrd")
    ap.add_argument("--rootfs")
    ap.add_argument("-o", "--output")
    args = ap.parse_args()

    with open(args.uinitrd, "rb") as f:
        d = f.read()
    hdr = bytearray(d[:64])
    size = struct.unpack_from(">I", hdr, 12)[0]
    if struct.unpack_from(">I", hdr, 0)[0] != UIMAGE_MAGIC or hdr[30] != 3 or hdr[31] != 0:
        sys.exit("not an uncompressed legacy ramdisk uImage")
    dec = zlib.decompressobj(31)
    cpio = dec.decompress(d[64:64 + size]) + dec.flush()

    entries = read_cpio(cpio)
    if args.rootfs:
        add_checkers(entries, args.rootfs)
    if "usr/sbin/fsck.ext4" not in {e.name for e in entries}:
        sys.exit("no fsck.ext4 in the initramfs (use --rootfs)")
    slimmed = entries if is_slim(entries) else slim(entries)
    f2fs_auto_fix(slimmed)
    f2fs_quiet_check(slimmed)
    packed = write_cpio(slimmed)
    payload = gzip.compress(packed, 9, mtime=0)
    if 64 + len(payload) > MAX_SIZE:
        sys.exit("uInitrd would overlap the dtb load address")

    struct.pack_into(">I", hdr, 12, len(payload))
    struct.pack_into(">I", hdr, 24, zlib.crc32(payload))
    struct.pack_into(">I", hdr, 4, 0)
    struct.pack_into(">I", hdr, 4, zlib.crc32(bytes(hdr)))
    out = args.output or args.uinitrd
    tmp = out + ".new"
    with open(tmp, "wb") as f:
        f.write(bytes(hdr) + payload)
    os.replace(tmp, out)
    print(f"  uInitrd: {len(d)} -> {64 + len(payload)} bytes, "
          f"cpio {len(cpio)} -> {len(packed)}, entries {len(entries)} -> {len(slimmed)}")


if __name__ == "__main__":
    main()
