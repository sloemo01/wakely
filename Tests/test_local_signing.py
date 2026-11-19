"""Local signing wiring guards. Never creates keys, trusts certs, or signs code."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
from unittest.mock import Mock, patch

root = Path(__file__).resolve().parents[1]
build = (root / 'build.sh').read_text()
setup = (root / 'Tools/Signing/setup-local-signing.py').read_text()
peer = (root / 'Helper/PeerAuthentication.swift').read_text()
client = (root / 'Sources/HelperClient.swift').read_text()
subprocess.run(['bash', '-n', str(root / 'build.sh')], check=True)
compile(setup, 'setup-local-signing.py', 'exec')
assert 'Wakely Local Development' in setup and 'Wakely Local Development' in build
assert "'-T', '/usr/bin/codesign'" in setup and "'-A'" not in setup
assert "'-p', 'codeSign'" in setup and "'-d'" not in setup
assert 'extendedKeyUsage = critical,codeSigning' in setup
assert 'TemporaryDirectory' in setup and "CONFIG.exists()" in setup
assert 'setup-local-signing.py' not in build, 'Build must not generate/rotate identities'
assert 'refusing ad-hoc fallback' in build
assert 'wakely-dev.keychain' not in build, 'Do not discover/reuse old unrelated identities'
assert 'designated => identifier' in build and 'certificate leaf = H' in build
assert 'sign_target "$APP" dev.wakely.app' in build
assert 'sign_target "$target" "$signing_id"' in build
assert 'certificate leaf = H' in peer and 'certificateRequirement()' in peer
assert 'skipping SMAppService registration' in client

namespace = {'__name__': 'local_signing_test'}
exec(compile(setup, 'setup-local-signing.py', 'exec'), namespace)
fingerprint = 'A' * 40
public_key_hash = 'A395F1D3' + 'B' * 28 + '548F'
certificate = f'''SHA-256 hash: {'C' * 64}
SHA-1 hash: {fingerprint.lower()}
keychain: "/configured/login.keychain-db"
attributes:
    "hpky"<blob>=0x{public_key_hash}  "public key hash"
'''
other_certificate = certificate.replace(fingerprint.lower(), 'D' * 40).replace(public_key_hash, 'E' * 40)
private_key = f'''keychain: "/configured/login.keychain-db"
version: 512
class: 0x00000010
attributes:
    0x00000001 ‹blob›="Imported Private Key"
    0x00000006 ‹blob›=0x{public_key_hash.lower()}  "public key hash"
'''
public_key = private_key.replace('class: 0x00000010', 'class: 0x0000000F')
with patch.object(subprocess, 'check_output', side_effect=[other_certificate + certificate, public_key + private_key]) as lookup, patch.object(subprocess, 'run') as command:
    namespace['allow_codesign_access']('/configured/login.keychain-db', fingerprint)
    assert lookup.call_args_list[0].args == (
        ['/usr/bin/security', 'find-certificate', '-a', '-c', 'Wakely Local Development',
         '-Z', '/configured/login.keychain-db'],)
    lookup.assert_called_with(['/usr/bin/security', 'dump-keychain', '/configured/login.keychain-db'], text=True)
    command.assert_called_once_with(
        ('/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:',
         '-s', '-l', 'Imported Private Key', '/configured/login.keychain-db'), check=True)
    assert '-k' not in command.call_args.args[0], 'Never pass the keychain password'
    assert '-a' not in command.call_args.args[0], 'Use the verified unique label, not the hash selector'
    assert not any(stream in command.call_args.kwargs for stream in ('stdin', 'stdout', 'stderr', 'capture_output'))

for output in ('', other_certificate, certificate + certificate,
               certificate.replace('"hpky"', '"missing"'),
               certificate + f'    "hpky"<blob>=0x{public_key_hash}\n'):
    with patch.object(subprocess, 'check_output', return_value=output), patch.object(subprocess, 'run') as command:
        try:
            namespace['allow_codesign_access']('/configured/login.keychain-db', fingerprint)
            raise AssertionError('Missing or ambiguous public-key hash must be refused')
        except SystemExit as error:
            assert 'No unique certificate/public-key hash' in str(error)
        command.assert_not_called()

for output in ('', public_key, private_key + private_key,
               private_key.replace(public_key_hash.lower(), 'F' * 40),
               private_key.replace('0x00000006', '0x00000007')):
    with patch.object(subprocess, 'check_output', side_effect=[certificate, output]), patch.object(subprocess, 'run') as command:
        try:
            namespace['allow_codesign_access']('/configured/login.keychain-db', fingerprint)
            raise AssertionError('Missing, duplicate, or mismatched private key must be refused')
        except SystemExit as error:
            assert 'Recover via Keychain Access' in str(error)
        command.assert_not_called()
with patch.object(subprocess, 'check_output', side_effect=[certificate, private_key.replace('‹', '<').replace('›', '>')]), patch.object(subprocess, 'run') as command:
    namespace['allow_codesign_access']('/configured/login.keychain-db', fingerprint)
    command.assert_called_once()

config = Mock()
config.exists.return_value = True
config.read_text.return_value = json.dumps({
    'name': 'Wakely Local Development', 'mode': 'local-certificate',
    'identity': 'A' * 40, 'keychain': '/configured/login.keychain-db'})
namespace['CONFIG'] = config
with patch.object(sys, 'argv', ['setup-local-signing.py']), patch.object(subprocess, 'run') as command:
    with contextlib.redirect_stdout(io.StringIO()):
        namespace['main']()
    command.assert_not_called()
with patch.object(sys, 'argv', ['setup-local-signing.py', '--allow-codesign-access']), patch.object(Path, 'is_file', return_value=True), patch.object(subprocess, 'check_output', side_effect=[certificate, private_key, certificate, private_key]), patch.object(subprocess, 'run') as command:
    namespace['main']()
    command.assert_called_once_with(
        ('/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:',
         '-s', '-l', 'Imported Private Key', '/configured/login.keychain-db'), check=True)
    command.side_effect = subprocess.CalledProcessError(1, 'security')
    try:
        namespace['main']()
        raise AssertionError('Partition-list failure must propagate')
    except subprocess.CalledProcessError:
        pass
config.exists.return_value = False
with patch.object(sys, 'argv', ['setup-local-signing.py', '--allow-codesign-access']), patch.object(subprocess, 'run') as command:
    try:
        namespace['main']()
        raise AssertionError('Migration must not create a missing identity')
    except SystemExit as error:
        assert 'will not create an identity' in str(error)
    command.assert_not_called()
config.write_text.assert_not_called()
assert "allow_codesign_access(KEYCHAIN, fingerprint)" in setup
assert setup.index("'-t', 'cert')") < setup.index('allow_codesign_access(KEYCHAIN, fingerprint)')
print('PASS: dedicated local identity, code-signing-only user trust, scoped key access, stable DR, no automatic identity rotation/fallback')
print('PASS: scoped Apple key partitions, inherited terminal, no password argument, opt-in migration without rotation')
print('PASS: fingerprint-matched public-key hash, missing/ambiguous matches refused, certificate imported before lookup')
print('PASS: unique private-key label verified against certificate hash, duplicate labels and mismatches refused, no partition -a/-k')
