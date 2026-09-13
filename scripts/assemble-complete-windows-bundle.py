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
MAX_PATH_BYTES = 32768
COPY_CHUNK = 8 * 1024 * 1024


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(COPY_CHUNK), b''):
            h.update(chunk)
    return h.hexdigest()


def safe_relative(name: str) -> Path:
    candidate = Path(name)
    if not name or candidate.is_absolute() or '..' in candidate.parts:
        raise SystemExit(f'Unsafe embedded payload path: {name!r}')
    return candidate


def read_trailer(exe: Path) -> tuple[int, int, int]:
    size = exe.stat().st_size
    if size < TRAILER_STRUCT.size:
        raise SystemExit('Source single executable is too small to contain an embedded runtime.')
    with exe.open('rb') as f:
        f.seek(size - TRAILER_STRUCT.size)
        raw = f.read(TRAILER_STRUCT.size)
    if len(raw) != TRAILER_STRUCT.size:
        raise SystemExit('Source single executable payload trailer is truncated.')
    magic, start, entries, length = TRAILER_STRUCT.unpack(raw)
    if magic != PAYLOAD_MAGIC:
        raise SystemExit('Source single executable does not contain an AUTM_PAYLOAD_V1 runtime.')
    if entries == 0:
        raise SystemExit('Source single executable payload is empty.')
    if start + length != size - TRAILER_STRUCT.size:
        raise SystemExit('Source single executable payload boundaries are invalid.')
    return start, entries, length


def extract_existing_payload(exe: Path, destination: Path) -> int:
    start, entries, length = read_trailer(exe)
    names: set[str] = set()
    destination.mkdir(parents=True, exist_ok=True)

    with exe.open('rb') as f:
        f.seek(start)
        payload_end = start + length
        for _ in range(entries):
            header = f.read(ENTRY_STRUCT.size)
            if len(header) != ENTRY_STRUCT.size:
                raise SystemExit('Truncated source payload entry header.')
            path_length, data_length = ENTRY_STRUCT.unpack(header)
            if path_length == 0 or path_length > MAX_PATH_BYTES:
                raise SystemExit(f'Invalid source payload path length: {path_length}')
            path_bytes = f.read(path_length)
            if len(path_bytes) != path_length:
                raise SystemExit('Truncated source payload path.')
            try:
                name = path_bytes.decode('utf-8')
            except UnicodeDecodeError as exc:
                raise SystemExit(f'Invalid UTF-8 source payload path: {exc}') from exc
            relative = safe_relative(name)
            normalized = relative.as_posix()
            if normalized in names:
                raise SystemExit(f'Duplicate source payload entry: {normalized}')
            names.add(normalized)

            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            remaining = data_length
            with target.open('wb') as out:
                while remaining:
                    chunk = f.read(min(COPY_CHUNK, remaining))
                    if not chunk:
                        raise SystemExit(f'Truncated source payload data: {normalized}')
                    out.write(chunk)
                    remaining -= len(chunk)

        if f.tell() != payload_end:
            raise SystemExit('Source payload parser did not terminate at the trailer boundary.')

    required = {
        'qemu/qemu-system-x86_64.exe',
        'qemu/qemu-system-aarch64.exe',
        'qemu/qemu-system-riscv64.exe',
        'qemu/qemu-img.exe',
        'package-manifest.json',
        'THIRD-PARTY-NOTICES.txt',
    }
    missing = sorted(required - names)
    if missing:
        raise SystemExit(f'Proven source single EXE payload is incomplete: {missing}')
    if not any(name.endswith('edk2-x86_64-code.fd') for name in names):
        raise SystemExit('Proven source single EXE payload has no x86_64 UEFI firmware.')
    return start


def append_file(out, path: Path, relative: str) -> None:
    encoded = relative.encode('utf-8')
    if not encoded or len(encoded) > MAX_PATH_BYTES:
        raise SystemExit(f'Invalid embedded payload path: {relative}')
    out.write(ENTRY_STRUCT.pack(len(encoded), path.stat().st_size))
    out.write(encoded)
    with path.open('rb') as src:
        shutil.copyfileobj(src, out, length=COPY_CHUNK)


def verify_overlay(exe: Path, expected_android_hash: str) -> tuple[int, int]:
    start, entries, length = read_trailer(exe)
    names: set[str] = set()
    android_hash = None

    with exe.open('rb') as f:
        f.seek(start)
        for _ in range(entries):
            header = f.read(ENTRY_STRUCT.size)
            if len(header) != ENTRY_STRUCT.size:
                raise SystemExit('Truncated final payload entry header.')
            path_length, data_length = ENTRY_STRUCT.unpack(header)
            if path_length == 0 or path_length > MAX_PATH_BYTES:
                raise SystemExit(f'Invalid final payload path length: {path_length}')
            path_bytes = f.read(path_length)
            if len(path_bytes) != path_length:
                raise SystemExit('Truncated final payload path.')
            name = path_bytes.decode('utf-8')
            safe_relative(name)
            if name in names:
                raise SystemExit(f'Duplicate final payload entry: {name}')
            names.add(name)

            if name == 'images/AccessibleAndroid.qcow2':
                h = hashlib.sha256()
                remaining = data_length
                while remaining:
                    chunk = f.read(min(COPY_CHUNK, remaining))
                    if not chunk:
                        raise SystemExit('Truncated Android image in final payload.')
                    h.update(chunk)
                    remaining -= len(chunk)
                android_hash = h.hexdigest()
            else:
                f.seek(data_length, 1)

        if f.tell() != start + length:
            raise SystemExit('Final payload parser did not terminate at the trailer boundary.')

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
    parser.add_argument('--single-exe-artifact', required=True, type=Path)
    parser.add_argument('--android-image', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--source-date-epoch', required=True, type=int)
    args = parser.parse_args()

    for path in (args.single_exe_artifact, args.android_image):
        if not path.is_file():
            raise SystemExit(f'Missing input file: {path}')
    if args.output.suffix.lower() != '.exe':
        raise SystemExit('The final user deliverable must be a single .exe file.')

    with tempfile.TemporaryDirectory(prefix='accessible-utm-final-one-file-') as temp_name:
        temp = Path(temp_name)
        artifact_dir = temp / 'artifact'
        payload_dir = temp / 'payload'
        artifact_dir.mkdir()
        payload_dir.mkdir()

        with zipfile.ZipFile(args.single_exe_artifact) as artifact:
            artifact.extractall(artifact_dir)

        candidates = sorted(artifact_dir.rglob('AccessibleUTM.exe'))
        if len(candidates) != 1:
            raise SystemExit(
                f'Expected exactly one proven AccessibleUTM.exe in the artifact, found {len(candidates)}'
            )
        source_exe = candidates[0]

        base_size = extract_existing_payload(source_exe, payload_dir)

        images = payload_dir / 'images'
        if images.exists():
            shutil.rmtree(images)
        images.mkdir()
        image_target = images / 'AccessibleAndroid.qcow2'
        shutil.copyfile(args.android_image, image_target)
        image_hash = sha256(image_target)

        manifest_path = payload_dir / 'package-manifest.json'
        try:
            manifest = json.loads(manifest_path.read_text(encoding='utf-8-sig'))
        except (OSError, json.JSONDecodeError) as exc:
            raise SystemExit(f'Cannot read proven source manifest: {exc}') from exc
        manifest.update(
            {
                'format': 'AUTM_PAYLOAD_V1',
                'product': 'AccessibleUTM + AccessibleAndroid 17 single executable',
                'complete_bundle': True,
                'source_commit': args.source_commit,
                'source_date_epoch': args.source_date_epoch,
                'android_image_included': True,
                'android_image_path': 'images/AccessibleAndroid.qcow2',
                'android_image_sha256': image_hash,
                'android_image_size': image_target.stat().st_size,
                'qemu_runtime': 'embedded',
                'runtime_extraction_root': '%LOCALAPPDATA%/AccessibleUTM/runtime',
                'user_facing_files': ['AccessibleUTM.exe'],
            }
        )
        manifest_path.write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False) + '\n', encoding='utf-8'
        )

        notices_path = payload_dir / 'THIRD-PARTY-NOTICES.txt'
        existing_notices = notices_path.read_text(encoding='utf-8-sig')
        notices_path.write_text(
            existing_notices.rstrip()
            + '\n\nAccessibleAndroid final delivery\n'
            + 'This final executable also embeds the BIOS/UEFI-proved AccessibleAndroid 17 QCOW2 image. '
            + 'No separate Android disk download or manual file placement is required.\n',
            encoding='utf-8',
        )

        files = sorted(
            (p for p in payload_dir.rglob('*') if p.is_file()),
            key=lambda p: p.relative_to(payload_dir).as_posix(),
        )
        if not files:
            raise SystemExit('Final payload has no files.')

        args.output.parent.mkdir(parents=True, exist_ok=True)
        if args.output.exists():
            args.output.unlink()

        with source_exe.open('rb') as src, args.output.open('wb') as out:
            remaining = base_size
            while remaining:
                chunk = src.read(min(COPY_CHUNK, remaining))
                if not chunk:
                    raise SystemExit('Source executable ended before its proven payload boundary.')
                out.write(chunk)
                remaining -= len(chunk)

            payload_start = out.tell()
            if payload_start != base_size:
                raise SystemExit('Base executable reconstruction boundary mismatch.')
            for path in files:
                append_file(out, path, path.relative_to(payload_dir).as_posix())
            payload_length = out.tell() - payload_start
            out.write(TRAILER_STRUCT.pack(PAYLOAD_MAGIC, payload_start, len(files), payload_length))

        entries, payload_length = verify_overlay(args.output, image_hash)
        output_hash = sha256(args.output)
        print('PROVEN_SINGLE_EXE_BASE_REUSED = PASS')
        print('ACCESSIBLE_UTM_FINAL_SINGLE_EXE = PASS')
        print('ACCESSIBLE_UTM_EMBEDDED_QEMU = PASS')
        print('ACCESSIBLE_UTM_EMBEDDED_UEFI = PASS')
        print('ACCESSIBLE_ANDROID_IMAGE_IN_EXE = PASS')
        print('USER_INSTALLS_NOTHING_ELSE = PASS')
        print(f'ANDROID_IMAGE_SHA256 = {image_hash}')
        print(f'ANDROID_IMAGE_SIZE = {image_target.stat().st_size}')
        print(f'PAYLOAD_FILE_COUNT = {entries}')
        print(f'PAYLOAD_SIZE = {payload_length}')
        print(f'FINAL_EXE = {args.output}')
        print(f'FINAL_EXE_SIZE = {args.output.stat().st_size}')
        print(f'FINAL_EXE_SHA256 = {output_hash}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
