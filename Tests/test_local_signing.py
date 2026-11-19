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
with patch.object(subprocess, 'run') as command:
    namespace['allow_codesign_access']('/configured/login.keychain-db')
    command.assert_called_once_with(
        ('/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:',
         '-s', '-l', 'wakely-private', '/configured/login.keychain-db'), check=True)
    assert '-k' not in command.call_args.args[0], 'Never pass the keychain password'
    assert not any(stream in command.call_args.kwargs for stream in ('stdin', 'stdout', 'stderr', 'capture_output'))

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
with patch.object(sys, 'argv', ['setup-local-signing.py', '--allow-codesign-access']), patch.object(Path, 'is_file', return_value=True), patch.object(subprocess, 'run') as command:
    namespace['main']()
    command.assert_called_once_with(
        ('/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:',
         '-s', '-l', 'wakely-private', '/configured/login.keychain-db'), check=True)
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
assert "allow_codesign_access(KEYCHAIN)" in setup
print('PASS: dedicated local identity, code-signing-only user trust, scoped key access, stable DR, no automatic identity rotation/fallback')
print('PASS: scoped Apple key partitions, inherited terminal, no password argument, opt-in migration without rotation')
