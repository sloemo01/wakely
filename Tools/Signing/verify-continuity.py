#!/usr/bin/env python3
"""Verify local signatures and identity continuity across changed app contents.

Signs only a disposable copy with the already configured key. Does not install
anything, change trust/TCC, launch the GUI, or enable any component.
"""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CONFIG = Path.home() / 'Library/Application Support/Wakely/Signing/identity.json'
TARGETS = {
    '.': 'dev.wakely.app',
    'Contents/MacOS/WakelyHelper': 'dev.wakely.helper',
    'Contents/MacOS/WakelyWatchdog': 'dev.wakely.watchdog',
    'Contents/Helpers/wakely-component': 'dev.wakely.component-tool',
}


def output(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True)


def requirement(identifier, fingerprint):
    return f'identifier "{identifier}" and certificate leaf = H"{fingerprint}"'


def check(path, identifier, fingerprint):
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--deep',
                    '--test-requirement', '=' + requirement(identifier, fingerprint),
                    str(path)], check=True)
    text = output('/usr/bin/codesign', '-d', '-r-', str(path))
    designated = next(line for line in text.splitlines() if line.startswith('designated =>'))
    assert 'cdhash' not in designated, 'A stable designated requirement cannot pin a build hash'
    assert identifier in designated and fingerprint.lower() in designated.lower()
    info = output('/usr/bin/codesign', '-d', '--verbose=4', str(path))
    cdhash = re.search(r'^CDHash=(\w+)$', info, re.M).group(1)
    return designated, cdhash


def main():
    config = json.loads(CONFIG.read_text())
    pin = config['identity'].upper()
    assert re.fullmatch('[0-9A-F]{40}', pin)
    app = (ROOT / 'build/Wakely.app').resolve()
    assert app.is_dir()
    records = {}
    with tempfile.TemporaryDirectory(prefix='wakely-signing-check-') as directory:
        work = Path(directory).resolve()
        assert work.is_dir() and work.name.startswith('wakely-signing-check-')
        for relative, identifier in TARGETS.items():
            target = app if relative == '.' else app / relative
            designated, cdhash = check(target, identifier, pin)
            prefix = str(work / identifier)
            subprocess.run(['/usr/bin/codesign', '-d', '--extract-certificates=' + prefix,
                            str(target)], check=True)
            leaf = Path(prefix + '0')
            assert hashlib.sha1(leaf.read_bytes()).hexdigest().upper() == pin
            records[identifier] = {'designatedRequirement': designated, 'cdhash': cdhash,
                                   'certificateSHA1': pin}
        variant = work / 'Wakely.app'
        shutil.copytree(app, variant, symlinks=True)
        (variant / 'Contents/Resources/signing-continuity-check.txt').write_text(
            'Disposable changed bundle: proves the designated identity does not depend on build contents.\n')
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', pin,
                        '--keychain', config['keychain'], '--timestamp=none',
                        '--identifier', 'dev.wakely.app', '--requirements',
                        '=designated => ' + requirement('dev.wakely.app', pin), str(variant)], check=True)
        designated, variant_hash = check(variant, 'dev.wakely.app', pin)
        first = records['dev.wakely.app']
        assert designated == first['designatedRequirement']
        assert variant_hash != first['cdhash'], 'Changed bundle must actually have a different code hash'
        wrong = subprocess.run(['/usr/bin/codesign', '--verify', '--test-requirement',
                                '=' + requirement('dev.wakely.app', '0' * 40), str(variant)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        assert wrong.returncode != 0, 'A different certificate must not satisfy the pin'
        helper_verified = False
        if '--probe-helper' in sys.argv:
            status = output(str(variant / 'Contents/MacOS/Wakely'), '--helper-status')
            assert 'reachable: true' in status, 'Helper did not accept the same-certificate changed bundle'
            helper_verified = True
            print('PASS: installed helper accepts changed-bundle cdhash with the same certificate, without reinstall')
        report = {'targets': records, 'changedBundleCDHash': variant_hash,
                  'helperAcceptedChangedBundle': helper_verified,
                  'sameDesignatedRequirementAfterChange': True,
                  'wrongCertificateRejected': True,
                  'guiAccessibilityUpgradeTested': False}
        report_path = ROOT / 'build/local-signing-verification.json'
        report_path.write_text(json.dumps(report, indent=2) + '\n')
        print('PASS: all four targets share the dedicated certificate and correct identifiers')
        print('PASS: changed bundle hash, identical designated requirement; wrong certificate refused')
        print('NOTE: this proves code identity continuity, not GUI Accessibility permission persistence')
        print('Report:', report_path)


if __name__ == '__main__':
    main()
