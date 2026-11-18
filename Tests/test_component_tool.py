"""End-to-end checks for the OSS component tool.

Everything the tests write lives in a temporary directory, except the tool's
own cache under build/tools. Nothing here launches the app.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "wakely-component"
BACKGROUND = bytes([0x0B, 0x0B, 0x0E])


def icon_rows(path):
    """The icon with any NN| row prefixes removed."""
    rows = []
    for line in path.read_text().splitlines():
        prefix, bar, rest = line.partition("|")
        rows.append(rest if bar and prefix.isdigit() else line)
    return rows


def read_ppm(path):
    data = path.read_bytes()
    magic, dimensions, maximum, pixels = data.split(b"\n", 3)
    width, height = map(int, dimensions.split())
    assert magic == b"P6"
    assert maximum == b"255"
    assert len(pixels) == width * height * 3
    return width, height, pixels


class ComponentToolTests(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory(prefix="wakely-component-tool-")
        self.temp = Path(self._directory.name)
        self.root = self.temp / "components"
        self.env = {key: value for key, value in os.environ.items() if key != "WAKELY_COMPONENTS_DIR"}

    def tearDown(self):
        self._directory.cleanup()

    def run_tool(self, *arguments, root=None, env=None):
        command = [str(TOOL), *arguments]
        if root is not None:
            command += ["--root", str(root)]
        return subprocess.run(command, cwd=self.temp, env=env or self.env,
                              capture_output=True, text=True)

    def make_component(self, component_id="sample-component"):
        result = self.run_tool("new", component_id, root=self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.root / component_id

    def set_manifest(self, folder, change):
        path = folder / "component.json"
        manifest = json.loads(path.read_text())
        change(manifest)
        path.write_text(json.dumps(manifest, indent=2) + "\n")

    def test_new_check_preview_round_trip(self):
        folder = self.make_component("sample-component")
        self.assertTrue((folder / "component.json").is_file())
        self.assertTrue((folder / "icon.txt").is_file())
        self.assertEqual(json.loads((folder / "component.json").read_text())["id"], "sample-component")
        self.assertEqual(icon_rows(folder / "icon.txt"), ["." * 32] * 32)

        checked = self.run_tool("check", "sample-component", root=self.root)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertIn("ok", checked.stdout.splitlines())
        self.assertIn("fill", checked.stdout)

        previewed = self.run_tool("preview", "sample-component", root=self.root)
        self.assertEqual(previewed.returncode, 0, previewed.stdout + previewed.stderr)
        paths = [Path(line) for line in previewed.stdout.splitlines()]
        self.assertEqual([path.name for path in paths], ["icon.ppm", "icon-8x.ppm", "card.ppm"])
        self.assertTrue(all(path.is_file() for path in paths))

        expected = {"icon.ppm": 32, "icon-8x.ppm": 256, "card.ppm": 56}
        for path in paths:
            with self.subTest(file=path.name):
                width, height, pixels = read_ppm(path)
                self.assertEqual((width, height), (expected[path.name], expected[path.name]))
                self.assertTrue(path.read_bytes().startswith(
                    f"P6\n{width} {height}\n255\n".encode()))
                self.assertEqual(set(pixels[i:i + 3] for i in range(0, len(pixels), 3)),
                                 {BACKGROUND})

    def test_unknown_field_is_rejected(self):
        folder = self.make_component()
        self.set_manifest(folder, lambda manifest: manifest.update({"author": "someone"}))
        result = self.run_tool("check", "sample-component", root=self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("component.json", result.stdout)
        self.assertIn("unknown field", result.stdout)

    def test_unknown_event_is_rejected(self):
        folder = self.make_component()
        self.set_manifest(folder, lambda manifest: manifest.update({
            "rules": [{"on": "moonPhase", "do": [{"notify": "The moon is full."}]}],
        }))
        result = self.run_tool("check", "sample-component", root=self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown or missing event", result.stdout)

    def test_short_icon_is_rejected(self):
        folder = self.make_component()
        (folder / "icon.txt").write_text("\n".join(["." * 32] * 31) + "\n")
        result = self.run_tool("check", "sample-component", root=self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("icon.txt", result.stdout)
        self.assertIn("32 lines", result.stdout)
        self.assertIn("31", result.stdout)

    def test_illegal_icon_character_is_rejected(self):
        folder = self.make_component()
        rows = ["." * 32] * 32
        rows[4] = "." * 5 + "x" + "." * 26
        (folder / "icon.txt").write_text("\n".join(rows) + "\n")
        result = self.run_tool("check", "sample-component", root=self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("line 5", result.stdout)
        self.assertIn("illegal character", result.stdout)
        self.assertIn(".nudbsliw", result.stdout)

    def test_traversal_id_is_refused(self):
        result = self.run_tool("new", "../escape", root=self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a valid component id", result.stdout + result.stderr)
        self.assertFalse((self.temp / "escape").exists())
        self.assertFalse((self.root.parent / "escape").exists())

    def test_duplicate_folder_is_refused(self):
        self.make_component()
        result = self.run_tool("new", "sample-component", root=self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stdout + result.stderr)

    def test_environment_root_is_used(self):
        env = dict(self.env, WAKELY_COMPONENTS_DIR=str(self.root))
        result = self.run_tool("new", "env-component", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "env-component" / "component.json").is_file())

    def test_shipped_examples_pass_check(self):
        examples = ROOT / "harvest" / "components-kit" / "sdk" / "examples"
        self.root.mkdir(parents=True)
        for example in sorted(examples.iterdir()):
            if not example.is_dir():
                continue
            with self.subTest(example=example.name):
                shutil.copytree(example, self.root / example.name)
                result = self.run_tool("check", example.name, root=self.root)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("ok", result.stdout.splitlines())


if __name__ == "__main__":
    unittest.main(verbosity=2)
