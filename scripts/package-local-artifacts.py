#!/usr/bin/env python3
"""Validate a complete native local build and stage its Actions download files."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil


BINARIES = {
    'app': ('Contents/MacOS/VPNNavigatorApp', 'com.javafancn.vpn-navigator'),
    'helper': ('Contents/Resources/VPNNavigatorHelper', 'com.javafancn.vpn-navigator.helper'),
    'agent': ('Contents/Resources/VPNNavigatorRuleAgent', 'com.javafancn.vpn-navigator.rule-agent'),
    'engine': ('Contents/Resources/openvpn', 'com.javafancn.vpn-navigator.openvpn'),
    'setup': ('Contents/Resources/VPNNavigatorLocalSetup', 'com.javafancn.vpn-navigator.local-setup'),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(file.read()).hexdigest()


def regular_file(path):
    require(path.is_file() and not path.is_symlink(), f'Missing or linked artifact: {path.name}')
    return path


def version_tuple(value):
    require(isinstance(value, str) and re.fullmatch(r'\d+(?:\.\d+){0,2}', value), 'Invalid minimum macOS version')
    parts = tuple(map(int, value.split('.')))
    return parts + (0,) * (3 - len(parts))


def stage(dist, architecture, output, source_sha, run_url):
    require(architecture in ('x86_64', 'arm64'), 'Unsupported architecture')
    require(re.fullmatch(r'[0-9a-f]{40}', source_sha), 'Expected exact source commit SHA')
    require(re.fullmatch(r'https://github\.com/[\w.-]+/[\w.-]+/actions/runs/\d+', run_url), 'Invalid Actions run URL')
    audit_path = regular_file(dist / f'VPN-Navigator-{architecture}-Local-audit.json')
    audit = json.loads(audit_path.read_text())
    version, build = audit['version'], str(audit['build'])
    require(isinstance(version, str) and re.fullmatch(r'\d+\.\d+\.\d+', version), 'Invalid package version')
    require(build.isdecimal() and int(build) > 0, 'Invalid bundle build')
    require(audit['architecture'] == architecture and audit['build_channel'] == 'local-test', 'Wrong architecture or build channel')
    minimum = version_tuple(audit['minimum_macos'])
    require(audit['binaries'], 'Missing binary audit')
    audited = {}
    for item in audit['binaries']:
        require(item['path'] not in audited, 'Duplicate binary audit path')
        require(item['architectures'] == [architecture], 'Binary is not the requested native architecture')
        require(item['minimum_macos'] and all(version_tuple(v) <= minimum for v in item['minimum_macos']), 'Binary exceeds declared minimum macOS')
        require(re.fullmatch(r'[0-9a-f]{64}', item['sha256']), 'Invalid binary checksum')
        audited[item['path']] = item
    require({'OpenVPN-source.tar.gz', 'OpenSSL-source.tar.gz'} <= {s['name'] for s in audit['sources']}, 'Matching engine sources missing')

    prefix = f'VPN-Navigator-{version}-{architecture}-Local'
    installer = regular_file(dist / (prefix + '.pkg'))
    uninstaller = regular_file(dist / (prefix + '-Uninstall.pkg'))
    checksums_path = regular_file(dist / (prefix + '-SHA256.txt'))
    manifest_path = regular_file(dist / (prefix + '-manifest.json'))
    manifest = json.loads(manifest_path.read_text())
    require(manifest['version'] == version and manifest['architecture'] == architecture and manifest['schema'] == 1, 'Approval manifest does not match build')
    for key, (path, identifier) in BINARIES.items():
        require(path in audited, f'Required binary missing: {key}')
        identity = manifest['binaries'][key]
        require(identity['identifier'] == identifier and identity['sha256'] == audited[path]['sha256'], f'Approval identity mismatch: {key}')
        require(re.fullmatch(r'[0-9a-f]{40}', identity['cdhash']), f'Invalid code identity: {key}')
    require(manifest['uninstallerSHA256'] == digest(uninstaller), 'Uninstaller approval mismatch')
    checksums = {}
    for line in checksums_path.read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})\s+\*?([^/\\]+)', line)
        require(match and match[2] not in checksums, 'Invalid or duplicate checksum entry')
        checksums[match[2]] = match[1]
    require(set(checksums) == {installer.name, uninstaller.name}, 'Checksum list must cover exactly both PKGs')
    require(all(digest(dist / name) == value for name, value in checksums.items()), 'PKG checksum mismatch')

    require(not output.exists() or (output.is_dir() and not output.is_symlink() and not any(output.iterdir())), 'Output must be a fresh empty directory')
    output.mkdir(parents=True, exist_ok=True)
    for path in (installer, uninstaller, checksums_path, manifest_path, audit_path):
        shutil.copy2(path, output / path.name)
    label = 'Intel' if architecture == 'x86_64' else '苹果 M 系列 / Apple Silicon'
    instructions = f'''VPN Navigator {version} / Build {build} — {label} ({architecture})
最低系统版本：macOS {audit['minimum_macos']}。

安装包：{installer.name}
卸载包：{uninstaller.name}

1. 解压后双击安装包，按系统安装器提示输入本机管理员密码。
2. 安装前先完整退出旧预览应用。若已安装可连接版本，先在设置中完成“升级与卸载准备”，保留配置并停用后台服务，再安装本包。
3. 从“应用程序”打开 VPN Navigator，检查本地安装批准、引擎和助手状态，导入自己的 .ovpn 验证连接与断开。
4. 本包内置 OpenVPN 引擎、助手、源码及许可证材料。它采用本地 ad-hoc 签名，未使用 Developer ID Installer 签名，未经 Apple 公证；系统可能显示开发者验证提示。系统操作说明：https://support.apple.com/zh-cn/102445
5. 卸载前先在应用中完成维护准备，等网络恢复及后台服务停用后，再运行对应卸载包。

在解压目录执行以下命令核对两份 PKG 的完整性：
shasum -a 256 -c {checksums_path.name}

源提交：{source_sha}
构建记录：{run_url}
本工作流负责构建和静态核验；安装、TLS/MFA、XPC、修复和卸载由独立的 Local test installer and XPC trust 工作流验收。真实网络防泄漏、macOS 13 真机等验收仍需记录。
'''
    (output / 'README-安装说明.txt').write_text(instructions, encoding='utf-8')
    provenance = {'version': version, 'build': build, 'architecture': architecture,
                  'minimum_macos': audit['minimum_macos'], 'channel': 'local-test',
                  'source_commit': source_sha, 'actions_run': run_url, 'pkg_sha256': checksums}
    (output / 'BUILD-INFO.json').write_text(json.dumps(provenance, ensure_ascii=False, indent=2) + '\n')
    return provenance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dist', type=Path, required=True)
    parser.add_argument('--architecture', choices=['x86_64', 'arm64'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--run-url', required=True)
    args = parser.parse_args()
    try:
        result = stage(args.dist, args.architecture, args.output, args.source_sha, args.run_url)
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, f'Installer artifact validation failed: {error}\n')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as file:
            for key in ('version', 'build', 'minimum_macos'):
                file.write(f'{key}={result[key]}\n')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
