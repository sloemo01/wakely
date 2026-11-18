"""Offscreen real-view tour snapshots; never launches AppDelegate or any power mode.
Run after build.sh: python3 Tests/verify-highlight-tour-layout.py
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
app = root / 'build/Wakely.app/Contents/MacOS/Wakely'
out = root.parent / 'wakely-onboarding/verification'
out.mkdir(parents=True, exist_ok=True)
steps = [0, 1, 2, 3, 4, 5, 6, 7, 13]
cases = [(step, '760x560', 'dark', False, False) for step in steps]
cases += [(step, '700x500', 'light', True, False) for step in steps]
cases += [(5, '760x560', 'dark', False, True), (6, '700x500', 'light', True, True)]
failures = []
for step, size, appearance, reduced, form in cases:
    name = f'step-{step:02}-{size}-{appearance}' + ('-form' if form else '')
    dest = out / (name + '.png')
    args = [str(app), '--render-guide-preview', str(dest), f'--onboarding-preview={step}',
            f'--guide-size={size}', f'--guide-{appearance}', '--verify-tour-layout']
    if step == 0 and size == '760x560': args.append('--verify-tour-flow')
    if reduced: args.append('--guide-reduced-motion')
    if form: args.append('--tour-show-form')
    run = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if run.returncode:
        failures.append(name)
        print(f'FAIL {name}:\n{run.stdout}\n{run.stderr}')
        # Keep a truthful visual artifact even when a layout assertion fails.
        subprocess.run([a for a in args if a != '--verify-tour-layout'],
                       capture_output=True, timeout=30)
    else:
        print(f'PASS {name}: target measured, coach on-window, saved settings untouched')
print(f'{len(cases) - len(failures)}/{len(cases)} real-view layout cases passed')
if failures: sys.exit(1)
