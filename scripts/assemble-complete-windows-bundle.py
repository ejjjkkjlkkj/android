#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import tempfile
import zipfile

PAYLOAD_MAGIC = b'AUTM_PAYLOAD_V1!'
TRAILER_STRUCT = struct.Struct('<16sQIQ')
ENTRY_STRUCT = struct.Struct('<IQ')


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(8 * 1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def append_file(out, path: Path, relative: str) -> None:
    encoded = relative.encode('utf-8')
    if not encoded or len(encoded) > 32768:
        raise SystemExit(f'Invalid embedded payload path: {relative}')
    out.write(ENTRY_STRUCT.pack(len(encoded), path.stat().st_size))
    out.write(encoded)
    with path.open('rb') as src:
        shutil.copyfileobj(src, out, length=8 * 1024 * 1024)


def verify_overlay(exe: Path, expected_android_hash: str) -> tuple[int, int]:
    size = exe.stat().st_size
    if size < TRAILER_STRUCT.size:
        raise SystemExit('Final executable is too small to contain the payload trailer.')

    with exe.open('rb') as f:
        f.seek(size - TRAILER_STRUCT.size)
        magic, start, entries, length = TRAILER_STRUCT.unpack(f.read(TRAILER_STRUCT.size))
        if magic != PAYLOAD_MAGIC:
            raise SystemExit('Final executable payload magic is missing.')
        if start + length != size - TRAILER_STRUCT.size:
            raise SystemExit('Final executable payload boundaries are invalid.')
        if entries == 0:
            raise SystemExit('Final executable payload is empty.')

        f.seek(start)
        names: set[str] = set()
        android_hash = None
        for _ in range(entries):
            header = f.read(ENTRY_STRUCT.size)
            if len(header) != ENTRY_STRUCT.size:
                raise SystemExit('Truncated payload entry header.')
            path_length, data_length = ENTRY_STRUCT.unpack(header)
            if path_length == 0 or path_length > 32768:
                raise SystemExit(f'Invalid payload path length: {path_length}')
            path_bytes = f.read(path_length)
            if len(path_bytes) != path_length:
                raise SystemExit('Truncated payload path.')
            name = path_bytes.decode('utf-8')
            if name.startswith('/') or '..' in Path(name).parts:
                raise SystemExit(f'Unsafe payload path: {name}')
            names.add(name)

            if name == 'images/AccessibleAndroid.qcow2':
                h = hashlib.sha256()
                remaining = data_length
                while remaining:
                    chunk = f.read(min(8 * 1024 * 1024, remaining))
                    if not chunk:
                        raise SystemExit('Truncated Android image in payload.')
                    h.update(chunk)
                    remaining -= len(chunk)
                android_hash = h.hexdigest()
            else:
                f.seek(data_length, 1)

        if f.tell() != start + length:
            raise SystemExit('Payload parser did not terminate at the trailer boundary.')

    required = {
        'qemu/qemu-system-x86_64.exe',
        'qemu/qemu-system-aarch64.exe',
        'qemu/qemu-system-riscv64.exe',
        'qemu/qemu-img.exe',
        'images/AccessibleAndroid.qcow2',
        'package-manifest.json',
        'THIRD-PARTY-NOTICES.txt',
    }
    missing = sorted(required - names)
    if missing:
        raise SystemExit(f'Final executable payload is incomplete: {missing}')
    if android_hash != expected_android_hash:
        raise SystemExit(
            f'Embedded Android image SHA-256 mismatch: {android_hash} != {expected_android_hash}'
        )
    if not any(name.endswith('edk2-x86_64-code.fd') for name in names):
        raise SystemExit('Final executable payload has no x86_64 UEFI firmware.')
    return entries, length


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--portable-artifact', required=True, type=Path)
    parser.add_argument('--android-image', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--source-date-epoch', required=True, type=int)
    args = parser.parse_args()

    for path in (args.portable_artifact, args.android_image):
        if not path.is_file():
            raise SystemExit(f'Missing input file: {path}')
    if args.output.suffix.lower() != '.exe':
        raise SystemExit('The final user deliverable must be a single .exe file.')

    with tempfile.TemporaryDirectory(prefix='accessible-utm-one-file-') as temp_name:
        temp = Path(temp_name)
        artifact_dir = temp / 'artifact'
        package_dir = temp / 'portable'
        payload_dir = temp / 'payload'
        artifact_dir.mkdir()
        package_dir.mkdir()
        payload_dir.mkdir()

        with zipfile.ZipFile(args.portable_artifact) as outer:
            outer.extractall(artifact_dir)

        portable_zips = sorted(artifact_dir.rglob('*-windows-x64-portable.zip'))
        if len(portable_zips) != 1:
            raise SystemExit(f'Expected exactly one portable ZIP, found {len(portable_zips)}')

        with zipfile.ZipFile(portable_zips[0]) as inner:
            inner.extractall(package_dir)

        required = [
            package_dir / 'AccessibleUTM.exe',
            package_dir / 'qemu/qemu-system-x86_64.exe',
            package_dir / 'qemu/qemu-system-aarch64.exe',
            package_dir / 'qemu/qemu-system-riscv64.exe',
            package_dir / 'qemu/qemu-img.exe',
        ]
        for path in required:
            if not path.is_file():
                raise SystemExit(f'Portable package is incomplete: {path.relative_to(package_dir)}')

        firmware_candidates = [
            package_dir / 'qemu/share/edk2-x86_64-code.fd',
            package_dir / 'qemu/share/qemu/edk2-x86_64-code.fd',
            package_dir / 'qemu/edk2-x86_64-code.fd',
        ]
        firmware = next((p for p in firmware_candidates if p.is_file()), None)
        if firmware is None:
            raise SystemExit('Portable package has no x86_64 UEFI firmware.')

        shutil.copytree(package_dir / 'qemu', payload_dir / 'qemu')
        images = payload_dir / 'images'
        images.mkdir()
        image_target = images / 'AccessibleAndroid.qcow2'
        shutil.copyfile(args.android_image, image_target)
        image_hash = sha256(image_target)

        manifest = {
            'format': 'AUTM_PAYLOAD_V1',
            'product': 'AccessibleUTM + AccessibleAndroid 17 single executable',
            'complete_bundle': True,
            'source_commit': args.source_commit,
            'source_date_epoch': args.source_date_epoch,
            'android_image_included': True,
            'android_image_path': 'images/AccessibleAndroid.qcow2',
            'android_image_sha256': image_hash,
            'qemu_runtime': 'embedded',
            'runtime_extraction_root': '%LOCALAPPDATA%/AccessibleUTM/runtime',
            'user_facing_files': ['AccessibleUTM.exe'],
        }
        (payload_dir / 'package-manifest.json').write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False) + '\n', encoding='utf-8'
        )
        (payload_dir / 'THIRD-PARTY-NOTICES.txt').write_text(
            'AccessibleUTM single-file Windows package\n\n'
            'This executable contains the QEMU runtime, QEMU firmware/data files, and the proved '
            'AccessibleAndroid 17 QCOW2 image. At first launch these embedded components are extracted '
            'automatically into the current user LocalAppData cache. No global QEMU installation, PATH '
            'change, separate Android image download, or administrator installation step is required.\n\n'
            'QEMU project: https://www.qemu.org/\n'
            'Windows QEMU distribution source: https://qemu.weilnetz.de/w64/\n',
            encoding='utf-8',
        )

        files = sorted(
            (p for p in payload_dir.rglob('*') if p.is_file()),
            key=lambda p: p.relative_to(payload_dir).as_posix(),
        )
        if not files:
            raise SystemExit('Payload has no files.')

        args.output.parent.mkdir(parents=True, exist_ok=True)
        if args.output.exists():
            args.output.unlink()

        base_exe = package_dir / 'AccessibleUTM.exe'
        with base_exe.open('rb') as src, args.output.open('wb') as out:
            shutil.copyfileobj(src, out, length=8 * 1024 * 1024)
            payload_start = out.tell()
            for path in files:
                append_file(out, path, path.relative_to(payload_dir).as_posix())
            payload_length = out.tell() - payload_start
            out.write(TRAILER_STRUCT.pack(PAYLOAD_MAGIC, payload_start, len(files), payload_length))

        entries, payload_length = verify_overlay(args.output, image_hash)
        output_hash = sha256(args.output)
        print('ACCESSIBLE_UTM_FINAL_SINGLE_EXE = PASS')
        print('ACCESSIBLE_UTM_EMBEDDED_QEMU = PASS')
        print('ACCESSIBLE_UTM_EMBEDDED_UEFI = PASS')
        print('ACCESSIBLE_ANDROID_IMAGE_IN_EXE = PASS')
        print('USER_INSTALLS_NOTHING_ELSE = PASS')
        print(f'ANDROID_IMAGE_SHA256 = {image_hash}')
        print(f'UEFI_FIRMWARE = {firmware.relative_to(package_dir).as_posix()}')
        print(f'PAYLOAD_FILE_COUNT = {entries}')
        print(f'PAYLOAD_SIZE = {payload_length}')
        print(f'FINAL_EXE = {args.output}')
        print(f'FINAL_EXE_SIZE = {args.output.stat().st_size}')
        print(f'FINAL_EXE_SHA256 = {output_hash}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
