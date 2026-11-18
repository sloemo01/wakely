"""Load the sprite authoring module without relying on a nonstandard helper."""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_art(name="wakely_sprites"):
    sys.path.insert(0, str(ROOT))
    spec = importlib.util.spec_from_file_location(name, ROOT / "generate-sprites.py")
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load generate-sprites.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module
