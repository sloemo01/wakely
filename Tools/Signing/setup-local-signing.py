#!/usr/bin/env python3
"""Explicit one-time creation of a Wakely-only local signing identity.

Never called by build.sh. The private key is imported into the user's login
Keychain, with codesign as the only explicitly allowed application. Only the
public certificate and non-secret fingerprint configuration are retained here.
No keychain is created/unlocked and no password is recorded.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

NAME = 'Wakely Local Development'
DIRECTORY = Path.home() / 'Library/Application Support/Wakely/Signing'
KEYCHAIN = Path.home() / 'Library/Keychains/login.keychain-db'
CONFIG = DIRECTORY / 'identity.json'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def allow_codesign_access(keychain, fingerprint):
    if not re.fullmatch(r'[0-9A-Fa-f]{40}', fingerprint):
        raise SystemExit('Invalid configured certificate fingerprint; refusing to change key access.')
    certificates = subprocess.check_output(
        ['/usr/bin/security', 'find-certificate', '-a', '-c', NAME, '-Z', str(keychain)],
        text=True)
    matches = []
    for block in re.split(r'(?m)^SHA-1 hash: *', certificates)[1:]:
        certificate_hash, _, attributes = block.partition('\n')
        if certificate_hash.strip().upper() == fingerprint.upper():
            matches.append(re.findall(r'(?m)^\s*"hpky"<blob>=0x([0-9A-Fa-f]{40})(?=\s|$)', attributes))
    if len(matches) != 1 or len(matches[0]) != 1:
        raise SystemExit('No unique certificate/public-key hash matches the configured fingerprint; refusing to change key access.')
    print('Allow Apple signing tools to use the Wakely key. Enter the keychain password when security prompts.')
    run('/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:',
        '-s', '-a', matches[0][0], str(keychain))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allow-codesign-access', action='store_true',
                        help='Allow Apple signing tools to use the existing Wakely key without rotating it.')
    args = parser.parse_args()
    if CONFIG.exists():
        config = json.loads(CONFIG.read_text())
        if args.allow_codesign_access:
            keychain = Path(config['keychain'])
            if config['name'] != NAME or config['mode'] != 'local-certificate' or not keychain.is_file():
                raise SystemExit('A configured Wakely local identity and existing keychain are required.')
            allow_codesign_access(keychain, config['identity'])
            return
        print('Local signing is already configured:', config['identity'])
        print('Reusing it is essential; do not generate a new certificate per build.')
        return
    if args.allow_codesign_access:
        raise SystemExit('No local signing configuration exists; access migration will not create an identity.')
    if DIRECTORY.is_symlink() or KEYCHAIN.is_symlink():
        raise SystemExit('Refusing unexpected symlink for signing directory/keychain.')
    if not KEYCHAIN.is_file():
        raise SystemExit('The login Keychain is missing; no keychain will be created automatically.')
    found = subprocess.run(['/usr/bin/security', 'find-certificate', '-c', NAME, str(KEYCHAIN)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if found.returncode == 0:
        raise SystemExit('A Wakely Local Development certificate already exists. Recover its configuration; do not rotate it silently.')
    openssl = shutil.which('openssl')
    if not openssl:
        raise SystemExit('OpenSSL is required.')
    DIRECTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(DIRECTORY, 0o700)
    # The only on-disk private key is in this freshly created, mode-0700
    # directory. No key/password is printed, committed, or copied to the app.
    with tempfile.TemporaryDirectory(prefix='wakely-signing-') as temporary:
        work = Path(temporary).resolve()
        assert work.is_dir() and work.name.startswith('wakely-signing-')
        os.chmod(work, 0o700)
        key = work / 'wakely-private.pem'
        cert = work / 'wakely-public.pem'
        der = work / 'wakely-public.cer'
        settings = work / 'openssl.cnf'
        settings.write_text('''[req]
prompt = no
distinguished_name = subject
x509_extensions = codesign
[subject]
CN = Wakely Local Development
O = Wakely Local Builds
[codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
''')
        previous = os.umask(0o077)
        try:
            run(openssl, 'genrsa', '-traditional', '-out', str(key), '3072',
                stdout=subprocess.DEVNULL)
            run(openssl, 'req', '-new', '-x509', '-sha256', '-days', '3650',
                '-key', str(key), '-out', str(cert), '-config', str(settings))
            run(openssl, 'x509', '-in', str(cert), '-outform', 'DER', '-out', str(der))
            fingerprint = hashlib.sha1(der.read_bytes()).hexdigest().upper()
            run('/usr/bin/security', 'import', str(key), '-k', str(KEYCHAIN),
                '-t', 'priv', '-f', 'openssl', '-T', '/usr/bin/codesign')
            run('/usr/bin/security', 'import', str(cert), '-k', str(KEYCHAIN), '-t', 'cert')
            allow_codesign_access(KEYCHAIN, fingerprint)
            # USER trust, constrained to code signing. No -d (system/admin)
            # and no SSL/SMIME/basic trust or unrestricted private-key ACL.
            run('/usr/bin/security', 'add-trusted-cert', '-r', 'trustRoot',
                '-p', 'codeSign', '-k', str(KEYCHAIN), str(cert))
            identities = subprocess.check_output(
                ['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning', str(KEYCHAIN)],
                text=True)
            if fingerprint not in identities:
                raise SystemExit('The certificate was imported, but is not a valid signing identity. Do not rerun setup to replace it; inspect Keychain.')
            (DIRECTORY / 'Wakely-Local-Development.cer').write_bytes(der.read_bytes())
            CONFIG.write_text(json.dumps({'name': NAME, 'identity': fingerprint,
                                          'keychain': str(KEYCHAIN), 'mode': 'local-certificate'}, indent=2) + '\n')
            print('Created dedicated code-signing identity:', fingerprint)
            print('Private key: login Keychain only; allowed signer: /usr/bin/codesign')
            print('Trust scope: current user, Code Signing only')
            print('Public certificate/config:', DIRECTORY)
        finally:
            os.umask(previous)
        # TemporaryDirectory removes only the exact freshly created work
        # directory verified above, including the transient private PEM.
    print('Temporary private-key files removed. Back up the identity securely via Keychain Access if needed.')


if __name__ == '__main__':
    main()
