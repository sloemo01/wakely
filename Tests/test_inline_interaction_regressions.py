"""Source integration guards for inline controls; no app or preference mutations.

These complement InlineValueModelTests: they check the UI uses the tested scrub
model and does not restore the non-observable binding / moving-target regressions.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
controls = (root / 'Sources/InlineValueChip.swift').read_text()
paragraph = (root / 'Sources/InlineChipText.swift').read_text()

assert 'coordinateSpace: .local' in controls, 'Drag coordinates use the stable chip width'
assert 'valueLabel(box: box)' in controls and '.highPriorityGesture(scrubGesture)' in controls, 'The numeric label owns a priority drag gesture'
assert '.frame(width: labelWidth' in controls, 'Numeric target width must remain stable'
assert 'domain.values + [clamped]' in controls, 'Width must cover every formatted domain value and legacy stored values'
assert '.font(Font(font))' in controls, 'Measured and rendered numeric fonts must match'
assert 'TorphText(' not in controls, 'Interactive labels must not retain departing glyphs'
cycle = controls.split('struct InlineCycleChip', 1)[1]
assert 'let _ = revision' in cycle and 'revision &+= 1' in cycle, 'Click must redraw without hover exit'
assert 'withAnimation' not in controls, 'Hover must not animate sentence geometry'
legacy = paragraph.split('struct ValueChip: View', 1)[1].split('struct OptionChip', 1)[0]
assert 'InlineValueChip(value: $value' in legacy, 'Legacy values must share the same interaction'
assert 'commitRequestedValue' not in legacy and 'walk(to:' not in legacy, 'No queued post-release changes'
option = paragraph.split('struct OptionChip', 1)[1]
assert 'revision &+= 1' in option and 'TorphText(' not in option, 'Menu choices must redraw immediately'
assert 'var height: CGFloat { ascent + descent }' in paragraph, 'Line height must include aligned descenders'
assert paragraph.count('lines(') >= 3, 'Measuring and placing must use the same line-breaking algorithm'
track = (root / 'Sources/PixelUI.swift').read_text().split('struct PixelStepper: View', 1)[1]
assert 'Slider(value: Binding(' in track, 'Track sliders use the native direct interaction'
assert 'Task.sleep' not in track and 'commitRequestedValue' not in track, 'Sliders never count after release'
assert 'TorphText(' not in track and 'revision &+= 1' in track, 'Track number updates with its saved value'
print('PASS: shared inline click, stable drag geometry, legacy parity, direct sliders and baseline layout guards')
