#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import zipfile


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(8 * 1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


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

    with tempfile.TemporaryDirectory(prefix='accessible-utm-complete-') as temp_name:
        temp = Path(temp_name)
        artifact_dir = temp / 'artifact'
        package_dir = temp / 'package'
        artifact_dir.mkdir()
        package_dir.mkdir()

        with zipfile.ZipFile(args.portable_artifact) as outer:
            outer.extractall(artifact_dir)

        portable_zips = sorted(artifact_dir.rglob('*-windows-x64-portable.zip'))
        if len(portable_zips) != 1:
            raise SystemExit(f'Expected exactly one portable ZIP, found {len(portable_zips)}')

        with zipfile.ZipFile(portable_zips[0]) as inner:
            inner.extractall(package_dir)

        required = [
            'AccessibleUTM.exe',
            'Verify-Runtime.ps1',
            'Install-AccessibleUTM.ps1',
            'Install-AccessibleUTM.cmd',
            'qemu/qemu-system-x86_64.exe',
            'qemu/qemu-system-aarch64.exe',
            'qemu/qemu-system-riscv64.exe',
            'qemu/qemu-img.exe',
            'package-manifest.json',
        ]
        for relative in required:
            if not (package_dir / relative).is_file():
                raise SystemExit(f'Portable package is incomplete: {relative}')

        firmware_candidates = [
            package_dir / 'qemu/share/edk2-x86_64-code.fd',
            package_dir / 'qemu/share/qemu/edk2-x86_64-code.fd',
            package_dir / 'qemu/edk2-x86_64-code.fd',
        ]
        firmware = next((p for p in firmware_candidates if p.is_file()), None)
        if firmware is None:
            raise SystemExit('Portable package has no x86_64 UEFI firmware')

        images = package_dir / 'images'
        images.mkdir(exist_ok=True)
        image_target = images / 'AccessibleAndroid.qcow2'
        shutil.copyfile(args.android_image, image_target)
        image_hash = sha256(image_target)

        manifest_path = package_dir / 'package-manifest.json'
        manifest = json.loads(manifest_path.read_text(encoding='utf-8-sig'))
        manifest.update({
            'product': 'AccessibleUTM + AccessibleAndroid 17 Complete',
            'android_image_included': True,
            'android_image_path': 'images/AccessibleAndroid.qcow2',
            'android_image_sha256': image_hash,
            'assembled_source_commit': args.source_commit,
            'complete_bundle': True,
        })
        manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')

        sums_path = package_dir / 'SHA256SUMS.txt'
        lines = []
        for path in sorted(p for p in package_dir.rglob('*') if p.is_file() and p != sums_path):
            relative = path.relative_to(package_dir).as_posix()
            lines.append(f'{sha256(path)}  {relative}')
        sums_path.write_text('\n'.join(lines) + '\n', encoding='ascii')

        args.output.parent.mkdir(parents=True, exist_ok=True)
        if args.output.exists():
            args.output.unlink()

        import datetime
        dt = datetime.datetime.fromtimestamp(args.source_date_epoch, tz=datetime.timezone.utc)
        year = min(max(dt.year, 1980), 2107)
        zip_time = (year, dt.month, dt.day, dt.hour, dt.minute, dt.second)

        with zipfile.ZipFile(args.output, 'w', compression=zipfile.ZIP_STORED, allowZip64=True) as out_zip:
            for path in sorted(p for p in package_dir.rglob('*') if p.is_file()):
                relative = path.relative_to(package_dir).as_posix()
                info = zipfile.ZipInfo(relative, zip_time)
                info.compress_type = zipfile.ZIP_STORED
                info.external_attr = 0o644 << 16
                with path.open('rb') as src, out_zip.open(info, 'w', force_zip64=True) as dst:
                    shutil.copyfileobj(src, dst, length=8 * 1024 * 1024)

        with zipfile.ZipFile(args.output) as proof:
            names = set(proof.namelist())
            for relative in required + ['images/AccessibleAndroid.qcow2', 'SHA256SUMS.txt']:
                if relative not in names:
                    raise SystemExit(f'Complete ZIP verification failed: {relative}')

        output_hash = sha256(args.output)
        Path(str(args.output) + '.sha256').write_text(f'{output_hash}  {args.output.name}\n', encoding='ascii')
        print('ACCESSIBLE_UTM_COMPLETE_BUNDLE = PASS')
        print('ACCESSIBLE_ANDROID_IMAGE_IN_BUNDLE = PASS')
        print(f'ANDROID_IMAGE_SHA256 = {image_hash}')
        print(f'UEFI_FIRMWARE = {firmware.relative_to(package_dir).as_posix()}')
        print(f'COMPLETE_BUNDLE = {args.output}')
        print(f'COMPLETE_BUNDLE_SHA256 = {output_hash}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
