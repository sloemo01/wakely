#!/usr/bin/env python3
"""One-time, explicitly invoked setup of a stable local code-signing identity."""

import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import tempfile


NAME = 'Wakely Local Development'
SIGNING = Path.home() / 'Library/Application Support/Wakely/Signing'
CONFIG = SIGNING / 'identity.json'


def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout


def main():
    if sys.platform != 'darwin':
        raise RuntimeError('Local signing setup runs only on macOS.')
    if CONFIG.exists() or CONFIG.is_symlink():
        raise RuntimeError('Signing configuration already exists; refusing to rotate the identity.')

    existing = subprocess.run(
        ['security', 'find-certificate', '-c', NAME, '-a'],
        capture_output=True, text=True,
    )
    if existing.returncode == 0:
        raise RuntimeError('A Wakely Local Development certificate already exists. '
                           'Recover the existing identity via Keychain Access; do not create another.')
    if existing.returncode != 44:
        raise RuntimeError('Cannot check for an existing certificate; no identity was created.')

    keychain = None
    for command in ('login-keychain', 'default-keychain'):
        result = subprocess.run(['security', command], capture_output=True, text=True)
        if result.returncode == 0:
            paths = shlex.split(result.stdout)
            if len(paths) == 1 and Path(paths[0]).is_file():
                keychain = paths[0]
                break
    if keychain is None or '\n' in keychain or '\t' in keychain:
        raise RuntimeError('An existing login keychain file is required. Open Keychain Access to recover it.')

    with tempfile.TemporaryDirectory(prefix='wakely-signing-') as directory:
        temp = Path(directory)
        temp.chmod(0o700)
        config = temp / 'openssl.cnf'
        key = temp / 'private.pem'
        cert = temp / 'certificate.pem'
        der = temp / 'certificate.cer'
        bundle = temp / 'identity.p12'
        config.write_text('''[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = Wakely Local Development
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
''')
        run(['openssl', 'req', '-new', '-x509', '-newkey', 'rsa:3072', '-nodes',
             '-sha256', '-days', '7300', '-config', str(config),
             '-keyout', str(key), '-out', str(cert)])
        run(['openssl', 'x509', '-in', str(cert), '-outform', 'DER', '-out', str(der)])
        fingerprint = hashlib.sha1(der.read_bytes()).hexdigest().upper()
        environment = dict(os.environ, WAKELY_P12_PASSWORD=secrets.token_urlsafe(32))
        legacy = ['-legacy'] if run(['openssl', 'version']).startswith('OpenSSL 3.') else []
        run(['openssl', 'pkcs12', '-export', *legacy, '-inkey', str(key),
             '-in', str(cert), '-name', NAME, '-out', str(bundle),
             '-passout', 'env:WAKELY_P12_PASSWORD'], env=environment)
        run(['security', 'import', str(bundle), '-k', keychain,
             '-P', environment['WAKELY_P12_PASSWORD'], '-T', '/usr/bin/codesign'])
        run(['security', 'add-trusted-cert', '-r', 'trustRoot', '-p', 'codeSign',
             '-k', keychain, str(der)])
        identities = run(['security', 'find-identity', '-v', '-p', 'codesigning', keychain])
        if fingerprint not in identities.upper():
            print('Warning: imported identity is not currently valid for code signing. '
                  'Inspect it in Keychain Access before building.', file=sys.stderr)

        SIGNING.mkdir(parents=True, exist_ok=True, mode=0o700)
        SIGNING.chmod(0o700)
        with open(CONFIG, 'x', opener=lambda path, flags: os.open(path, flags, 0o600)) as output:
            CONFIG.chmod(0o600)
            (SIGNING / 'Wakely-Local-Development.cer').write_bytes(der.read_bytes())
            json.dump({'mode': 'local-certificate', 'name': NAME,
                       'identity': fingerprint, 'keychain': keychain}, output, indent=2)
            output.write('\n')
    print(f'Configured {NAME}: {fingerprint}')
    print('Keep an encrypted private-key backup using Keychain Access. This is not Developer ID or notarization.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            message = f'{error.cmd[0]} failed (exit {error.returncode}).'
        else:
            message = str(error)
        print(f'Error: {message} If import already occurred, recover via Keychain Access; '
              'do not generate a replacement identity.', file=sys.stderr)
        sys.exit(1)
