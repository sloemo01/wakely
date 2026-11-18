"""Local signing wiring guards. Never creates keys, trusts certs, or signs code."""
from pathlib import Path
import subprocess

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
print('PASS: dedicated local identity, code-signing-only user trust, scoped key access, stable DR, no automatic identity rotation/fallback')
