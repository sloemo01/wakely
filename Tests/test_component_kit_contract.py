#!/usr/bin/env python3
"""Source/format contract for the Add Your Own Component kit.

This test reads repository files only. It never launches Wakely, runs a helper,
touches hardware, installs anything, or changes a system setting.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / "harvest" / "components-kit"
SDK = KIT / "sdk"

REQUIRED_KIT_FILES = (
    "README.txt",
    "AGENTS.md",
    "CLAUDE.md",
    ".kit-version",
    "sdk/reference.md",
    "sdk/component.schema.json",
    "sdk/template/component.json",
)

# Vocabulary the schema must cover, both in its rule shapes and its definitions.
REQUIRED_SCHEMA_VOCABULARY = (
    "keepAwakeWhile",
    "closedFor",
    "sessionFor",
    "batteryBelow",
    "endSession",
    "notify",
    "when",
    "choiceIs",
    "timeBetween",
)

failures = []


def check(condition, message):
    """Record a failure and keep going, so the report names every broken assertion."""
    if not condition:
        failures.append(message)
    return bool(condition)


def rel(path):
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def read_text(path):
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        check(False, "%s is not readable UTF-8 text: %s" % (rel(path), error))
        return None


def load_json(path):
    text = read_text(path)
    if text is None:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        check(False, "%s is not valid JSON: %s" % (rel(path), error))
        return None


def structural_vocabulary(node):
    """Every property name, required key and enum value under a schema node."""
    found = set()

    def walk(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key == "properties" and isinstance(child, dict):
                    found.update(name for name in child if isinstance(name, str))
                    for item in child.values():
                        walk(item)
                elif key == "required" and isinstance(child, list):
                    found.update(name for name in child if isinstance(name, str))
                elif key == "enum" and isinstance(child, list):
                    found.update(name for name in child if isinstance(name, str))
                else:
                    walk(child)
        elif isinstance(value, list):
            for item in value:
                walk(item)

    walk(node)
    return found


def mentions(text, word):
    """The word as a standalone token, so 'not' does not match 'notification'."""
    pattern = r"(?<![A-Za-z0-9_])" + re.escape(word) + r"(?![A-Za-z0-9_])"
    return re.search(pattern, text) is not None


def sentences(text):
    """Flattened sentence list, so wrapped markdown lines stay readable."""
    return [sentence for sentence in re.split(r"(?<=[.!?])\s+", " ".join(text.split())) if sentence]


# 1. The kit's required files.
if not KIT.is_dir():
    check(False, "component kit folder is missing: %s" % rel(KIT))
else:
    for relative in REQUIRED_KIT_FILES:
        check((KIT / relative).is_file(), "missing required kit file: %s" % relative)


# 2. The kit version is 4, and the app's refresh constant matches it.
version_path = KIT / ".kit-version"
if version_path.is_file():
    version_text = read_text(version_path)
    if version_text is not None:
        check(
            version_text.strip() == "4",
            ".kit-version must be exactly 4, found %r" % version_text,
        )

launcher_path = ROOT / "Sources" / "ComponentKitLauncher.swift"
if launcher_path.is_file():
    launcher_text = read_text(launcher_path)
    if launcher_text is not None:
        match = re.search(r'static\s+let\s+kitVersion\s*=\s*"([^"]*)"', launcher_text)
        if check(match is not None, "Sources/ComponentKitLauncher.swift must define kitVersion"):
            check(
                match.group(1) == "4",
                'ComponentKitLauncher.kitVersion must be "4" so the installed kit refreshes, found %r'
                % match.group(1),
            )


# 3. Every example is a complete, loadable format 1 component with a 32x32 icon.
examples_directory = SDK / "examples"
if not examples_directory.is_dir():
    check(False, "missing required kit folder: sdk/examples")
else:
    examples = sorted(path for path in examples_directory.iterdir() if path.is_dir())
    check(bool(examples), "sdk/examples must contain at least one example folder")

    for example in examples:
        example_rel = rel(example)
        manifest_path = example / "component.json"
        if not manifest_path.is_file():
            check(False, "%s/component.json is missing" % example_rel)
        else:
            manifest = load_json(manifest_path)
            if manifest is not None:
                if check(isinstance(manifest, dict), "%s/component.json must be a JSON object" % example_rel):
                    check(
                        manifest.get("format") == 1,
                        "%s/component.json format must be 1, found %r"
                        % (example_rel, manifest.get("format")),
                    )
                    check(
                        manifest.get("id") == example.name,
                        "%s/component.json id must match its folder %r, found %r"
                        % (example_rel, example.name, manifest.get("id")),
                    )
                    rules = manifest.get("rules")
                    check(
                        isinstance(rules, list) and len(rules) > 0,
                        "%s/component.json must have nonempty rules" % example_rel,
                    )

        icon_path = example / "icon.txt"
        if not icon_path.is_file():
            check(False, "%s/icon.txt is missing" % example_rel)
        else:
            icon_text = read_text(icon_path)
            if icon_text is not None:
                lines = icon_text.splitlines()
                check(
                    len(lines) == 32,
                    "%s/icon.txt must be exactly 32 nonempty lines, found %d lines"
                    % (example_rel, len(lines)),
                )
                empty_lines = [number for number, line in enumerate(lines, 1) if not line.strip()]
                check(
                    not empty_lines,
                    "%s/icon.txt must not contain empty lines (line %s)"
                    % (example_rel, ", ".join(str(number) for number in empty_lines[:3]) or "?"),
                )
                wrong_lengths = [
                    (number, len(line))
                    for number, line in enumerate(lines, 1)
                    if len(line) != 32
                ]
                check(
                    not wrong_lengths,
                    "%s/icon.txt lines must be 32 characters; line %d is %d"
                    % (
                        example_rel,
                        wrong_lengths[0][0] if wrong_lengths else 0,
                        wrong_lengths[0][1] if wrong_lengths else 0,
                    ),
                )


# 4. The schema is valid JSON and its rule/event/action/condition vocabulary covers the kit.
schema_events = set()
schema_actions = set()
schema_conditions = set()

schema_path = SDK / "component.schema.json"
if schema_path.is_file():
    schema = load_json(schema_path)
    if check(isinstance(schema, dict), "sdk/component.schema.json must be a JSON object"):
        definitions = schema.get("$defs")
        if check(isinstance(definitions, dict), "sdk/component.schema.json must define $defs"):
            vocabulary = structural_vocabulary(schema)
            for token in REQUIRED_SCHEMA_VOCABULARY:
                check(
                    token in vocabulary,
                    "schema vocabulary does not cover %r" % token,
                )

            rule_variants = definitions.get("rule", {}).get("oneOf", [])
            if not isinstance(rule_variants, list):
                rule_variants = []
            check(bool(rule_variants), "schema $defs.rule must define rule shapes")
            check(
                any(
                    isinstance(variant, dict)
                    and "keepAwakeWhile" in variant.get("properties", {})
                    for variant in rule_variants
                ),
                "schema $defs.rule must define the keepAwakeWhile rule",
            )

            event_variant = next(
                (
                    variant
                    for variant in rule_variants
                    if isinstance(variant, dict) and "on" in variant.get("properties", {})
                ),
                None,
            )
            if check(event_variant is not None, "schema $defs.rule must define an event rule"):
                event_values = event_variant.get("properties", {}).get("on", {}).get("enum", [])
                schema_events = {value for value in event_values if isinstance(value, str)}
                check(bool(schema_events), "schema event rule must enumerate its events")

            action_variants = definitions.get("action", {}).get("oneOf", [])
            if isinstance(action_variants, list):
                for variant in action_variants:
                    if isinstance(variant, dict):
                        schema_actions.update(variant.get("properties", {}))
            for token in ("endSession", "notify"):
                check(token in schema_actions, "schema $defs.action must define %r" % token)

            condition_definition = definitions.get("condition")
            if check(isinstance(condition_definition, dict), "schema must define $defs.condition"):
                schema_conditions = structural_vocabulary(condition_definition)
                for token in ("lidClosed", "sessionActive"):
                    check(
                        token in schema_conditions,
                        "schema condition vocabulary must define %r" % token,
                    )

            hold_definition = definitions.get("holdCondition")
            if check(isinstance(hold_definition, dict), "schema must define $defs.holdCondition"):
                hold_vocabulary = structural_vocabulary(hold_definition)
                check(
                    not ({"lidClosed", "sessionActive"} & hold_vocabulary),
                    "schema $defs.holdCondition must reject lidClosed and sessionActive",
                )


# 5. The reference mentions every event/action/condition the schema defines, and
#    states the lidClosed/sessionActive restriction explicitly.
reference_path = SDK / "reference.md"
if reference_path.is_file():
    reference_text = read_text(reference_path)
    if reference_text is not None:
        for name in sorted(schema_events | schema_actions | schema_conditions):
            check(
                mentions(reference_text, name),
                "sdk/reference.md does not mention schema vocabulary %r" % name,
            )

        for name in ("lidClosed", "sessionActive"):
            name_lines = [line for line in reference_text.splitlines() if name in line]
            check(
                any(
                    "only" in line.lower() and "when" in line.lower()
                    for line in name_lines
                ),
                'sdk/reference.md must say %r is only for an event rule\'s "when"' % name,
            )
        check(
            re.search(
                r"keepawakewhile[^.]{0,120}(reject|never|not allow)|"
                r"(reject|never|not allow)[^.]{0,120}keepawakewhile",
                reference_text,
                re.IGNORECASE | re.DOTALL,
            )
            is not None,
            "sdk/reference.md must say keepAwakeWhile rejects lidClosed and sessionActive",
        )


# 6. AGENTS.md summarizes the rules and points at the machine-readable sources;
#    README.txt explains a versioned refresh that leaves user components alone.
agents_path = KIT / "AGENTS.md"
if agents_path.is_file():
    agents_text = read_text(agents_path)
    if agents_text is not None:
        check(
            re.search(r"^#{2,3}\s+.*rules", agents_text, re.IGNORECASE | re.MULTILINE) is not None,
            "AGENTS.md must contain a rules summary heading",
        )
        for token in ("keepAwakeWhile", "endSession", "notify"):
            check(token in agents_text, "AGENTS.md rules summary must cover %r" % token)
        for target in ("sdk/reference.md", "sdk/component.schema.json"):
            check(target in agents_text, "AGENTS.md must point to %s" % target)

readme_path = KIT / "README.txt"
if readme_path.is_file():
    readme_text = read_text(readme_path)
    if readme_text is not None:
        check("sdk" in readme_text, "README.txt must mention the sdk folder")
        readme_sentences = sentences(readme_text)
        refresh_sentence = next(
            (
                sentence
                for sentence in readme_sentences
                if re.search(r"\b(rewrites|refreshes|replaces|updates)\b", sentence, re.IGNORECASE)
                and ("sdk" in sentence.lower() or "documents" in sentence.lower())
            ),
            None,
        )
        if check(
            refresh_sentence is not None,
            "README.txt must say Wakely refreshes the kit documents and sdk",
        ):
            check(
                re.search(r"version|update", refresh_sentence, re.IGNORECASE) is not None,
                "README.txt must tie the kit document/sdk refresh to a version change",
            )
        check(
            any(
                "components" in sentence.lower()
                and re.search(r"never|untouched|does not touch|doesn't touch", sentence, re.IGNORECASE)
                for sentence in readme_sentences
            ),
            "README.txt must say the user's components are untouched",
        )
        check("Custom" in readme_text, 'README.txt must call the group "Custom"')


# 7. No kit text still uses the old product name or the old group name.
saw_custom = False
if KIT.is_dir():
    for path in sorted(KIT.rglob("*")):
        if not path.is_file():
            continue
        try:
            data = path.read_bytes()
        except OSError as error:
            check(False, "%s could not be read: %s" % (rel(path), error))
            continue
        if b"\x00" in data:
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        for old in ("Your Components",):
            check(
                old not in text,
                "%s must not contain %r; the group is Custom" % (rel(path), old),
            )
        if "Custom" in text:
            saw_custom = True
check(saw_custom, 'kit text must call the group "Custom"')


# 8. The prompt in Components.swift names the documents the agent must read.
components_path = ROOT / "Sources" / "Components.swift"
components_text = read_text(components_path) if components_path.is_file() else None
if components_text is not None:
    prompt_match = re.search(
        r"var\s+newComponentPrompt\s*:\s*String\s*\{(.*?)\n\s*\}",
        components_text,
        re.DOTALL,
    )
    if check(prompt_match is not None, "Sources/Components.swift must define newComponentPrompt"):
        prompt_body = prompt_match.group(1)
        for target in ("AGENTS.md", "sdk/reference.md", "sdk/component.schema.json"):
            check(
                target in prompt_body,
                "newComponentPrompt must mention %s" % target,
            )


# 9. The Make Your Own sheet says the component appears in the Custom group.
settings_path = ROOT / "Sources" / "SettingsUI.swift"
settings_text = read_text(settings_path) if settings_path.is_file() else None
if settings_text is not None:
    sheet_start = settings_text.find("private struct MakeYourOwnSheet")
    if check(sheet_start != -1, "Sources/SettingsUI.swift must define MakeYourOwnSheet"):
        rest = settings_text[sheet_start + len("private struct MakeYourOwnSheet") :]
        following = re.search(
            r"\n(?:private |public |internal |final )*(?:struct|class|enum|extension)\s+[A-Za-z_]",
            rest,
        )
        sheet_text = rest[: following.start()] if following else rest
        check("Custom" in sheet_text, "MakeYourOwnSheet copy must use Custom")
        for old in ("Your Components",):
            check(old not in sheet_text, "MakeYourOwnSheet must not use %r" % old)
        custom_lines = [line for line in sheet_text.splitlines() if "Custom" in line]
        check(
            any("component" in line.lower() or "appears" in line.lower() for line in custom_lines),
            'the Make Your Own copy must say the component appears in the Custom group',
        )


# 10. Components.swift refreshes the kit documents on a version change, backing up
#     the old copies, and records the new version only after the refresh succeeds.
if components_text is not None:
    signature = re.search(r"func\s+refreshKitDocuments\(([^)]*)\)", components_text)
    if check(signature is not None, "Sources/Components.swift must define refreshKitDocuments(...)"):
        check(
            "previousVersion" in signature.group(1),
            "refreshKitDocuments must know the previous kit version",
        )
    code_lines = [
        line
        for line in components_text.splitlines()
        if not line.lstrip().startswith("//")
    ]
    check(
        re.search(r"\.docs-(?:before|backup)-", "\n".join(code_lines)) is not None,
        "Components.swift must back up the old kit documents before replacing them",
    )

    function_start = components_text.find("func refreshKitDocuments(")
    if function_start != -1:
        function_rest = components_text[function_start:]
        function_end = re.search(r"\n    \}\n", function_rest)
        function_body = function_rest[: function_end.end()] if function_end else function_rest[:5000]
        for document in ("README.txt", "AGENTS.md", "CLAUDE.md"):
            check(
                '"%s"' % document in function_body,
                "refreshKitDocuments must refresh %s" % document,
            )
        copy_position = function_body.find("copyItem(at: destination, to: saved)")
        write_position = function_body.find("write(to: destination")
        check(copy_position != -1, "refreshKitDocuments must copy an old document into its backup")
        check(write_position != -1, "refreshKitDocuments must replace the old document")
        if copy_position != -1 and write_position != -1:
            check(
                copy_position < write_position,
                "the backup must be written before the document is replaced",
            )
        check(
            "if !fm.fileExists(atPath: saved.path)" in function_body,
            "an existing backup must be kept, not overwritten on a retry",
        )

    check(
        re.search(r"if\s+installedVersion\s*==\s*ComponentKitLauncher\.kitVersion", components_text)
        is not None,
        "kit documents must be refreshed only when the kit version changes",
    )
    guard_position = components_text.find("guard refreshKitDocuments(")
    write_position = components_text.find("ComponentKitLauncher.kitVersion.write")
    check(guard_position != -1, "installKitIfNeeded must require a successful document refresh")
    check(write_position != -1, "installKitIfNeeded must record the installed kit version")
    if guard_position != -1 and write_position != -1:
        check(
            guard_position < write_position,
            "the kit version must be recorded only after the document refresh succeeds",
        )
        guard_block = components_text[guard_position:write_position]
        check(
            "return" in guard_block,
            "a failed document refresh must return before the version is recorded, so the next launch retries",
        )


if failures:
    unique_failures = list(dict.fromkeys(failures))
    for message in unique_failures:
        print("FAIL: %s" % message)
    print("FAIL: %d component-kit contract assertion(s) failed" % len(unique_failures))
    sys.exit(1)

print(
    "PASS: kit files, version 4, examples and icons, schema vocabulary, reference coverage, "
    "AGENTS/README contracts, no old names, prompt, Custom sheet copy, and versioned "
    "document refresh/backup all match"
)
