"""CLI: python3 Tools/test_tools.py.
Проверка смонтированного DMG: .build/dmg-tools/bin/python Tools/test_tools.py /Volumes/Aza
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def check_scripts():
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        tools = root / "Tools"
        (tools / "BuildChechenLexicon").mkdir(parents=True)
        binary = root / "bin"
        binary.mkdir()
        for name in ("swift", "python3", "hdiutil", "defaults"):
            (binary / name).symlink_to("/usr/bin/true")
        for name, source in {
            "xcodebuild": 'mkdir -p build_release/Build/Products/Release/Aza.app\n'
                          'for ((i=0;i<20000;i++)); do echo "-module-name Aza -D DEBUG $i"; done\n',
            "codesign": 'if [ "$1" = -dv ]; then echo "flags=0x10000(runtime)" >&2; fi\n',
        }.items():
            path = binary / name
            path.write_text("#!/bin/bash\n" + source)
            path.chmod(0o755)
        environment = {**os.environ, "PATH": str(binary) + os.pathsep + os.environ["PATH"]}
        for name in ("check.sh", "release.sh"):
            shutil.copyfile(ROOT / "Tools" / name, tools / name)
        result = subprocess.run(["/bin/bash", str(tools / "release.sh"), "--local"],
                                cwd=root, env=environment, capture_output=True, text=True)
        assert result.returncode != 0 and "условием DEBUG" in result.stdout, result
        # bash -n file1 file2 проверял только file1 и пропускал сломанный релиз.
        (tools / "release.sh").write_text("if then\n")
        result = subprocess.run(["/bin/bash", str(tools / "check.sh")],
                                cwd=root, env=environment, capture_output=True, text=True)
        assert result.returncode != 0 and "release.sh" in result.stderr, result


def check_duplicate_cities():
    spec = importlib.util.spec_from_file_location(
        "schedules", ROOT / "Tools/import-caucasus-schedules.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        catalog = root / "Aza/Resources/prayer-schedules-2026.json"
        catalog.parent.mkdir(parents=True)
        module.__file__ = str(root / "Tools/import-caucasus-schedules.py")
        entry = {"name": "Грозный", "id": "грозный", "days": [],
                 "coverageStatus": "complete", "source": {"name": "test"}}
        module.read_makhachkala = lambda _: entry
        module.read_nalchik = lambda _: entry
        original_argv = sys.argv
        try:
            for existing in ([], [entry]):
                catalog.write_text(json.dumps({"cities": existing}))
                sys.argv = [module.__file__, temporary, "--write", "--replace"]
                with contextlib.redirect_stdout(io.StringIO()):
                    assert module.main() == 0
                assert json.loads(catalog.read_text())["cities"] == [entry]
        finally:
            sys.argv = original_argv


def check_dmg_layout(volume):
    from ds_store import DSStore
    from mac_alias import Alias

    assert (volume / "Applications").is_symlink()
    assert os.readlink(volume / "Applications") == "/Applications"
    with DSStore.open(str(volume / ".DS_Store"), "r") as store:
        app, folder = store["Aza.app"]["Iloc"], store["Applications"]["Iloc"]
        view = store["."]["icvp"]
        assert app[0] < folder[0] and app[1] == folder[1], "Aza должна быть слева"
        assert folder[0] - app[0] > 2 * view["iconSize"], "Нет места для стрелки"
        assert store["."]["icvl"][1] == b"icnv" and view["arrangeBy"] == "none"
        assert view["backgroundType"] == 2
        background = Alias.from_bytes(view["backgroundImageAlias"]).target.filename
        assert (volume / background).is_file(), "Finder не найдёт фон с инструкцией"
        # Проверяем ссылку через macOS, а не только наличие файла в образе.
        with tempfile.NamedTemporaryFile() as bookmark:
            bookmark.write(store["."]["pBBk"].to_bytes())
            bookmark.flush()
            subprocess.run(["swift", "-e", """
import Foundation
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
var stale = false
let resolved = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                       relativeTo: nil, bookmarkDataIsStale: &stale)
let expected = URL(fileURLWithPath: CommandLine.arguments[2])
precondition(resolved.resolvingSymlinksInPath() == expected.resolvingSymlinksInPath())
""", bookmark.name, str(volume / background)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(volume / "Aza.app")],
                   check=True)
    check_app_permissions(volume / "Aza.app")


def check_app_permissions(app):
    app = Path(app)
    entitlements = plistlib.loads(subprocess.check_output(
        ["codesign", "-d", "--entitlements", "-", "--xml", str(app)]))
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    for entitlement, description in [
        ("com.apple.security.personal-information.location", "NSLocationUsageDescription"),
        ("com.apple.security.device.audio-input", "NSMicrophoneUsageDescription"),
    ]:
        assert entitlements.get(entitlement) is True, "В подписи отсутствует " + entitlement
        assert isinstance(info.get(description), str) and info[description].strip(), \
            "В Info.plist отсутствует описание " + description



if __name__ == "__main__":
    check_scripts()
    check_duplicate_cities()
    if len(sys.argv) > 1:
        check_dmg_layout(Path(sys.argv[1]))
    print("CLI regression checks passed")
