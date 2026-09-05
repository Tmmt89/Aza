"""Build the Finder layout with a native, relocatable background bookmark."""
from pathlib import Path
import subprocess
import sys

import dmgbuild
from ds_store import DSStore
from mac_alias import Bookmark


def build(app, background, output):
    volume = None

    def finalize_background(event):
        nonlocal volume
        if (event.get("command") == "hdiutil::attach"
                and event["type"] == "command::finished" and event["ret"] == 0):
            volume = next(Path(item["mount-point"])
                          for item in event["output"]["system-entities"] if "mount-point" in item)
        if event.get("operation") == "dsstore::create" and event["type"] == "operation::finished":
            # mac_alias 2.2.2's pBBk fails native resolution after a remount.
            # Foundation records the volume identity and the file reference correctly.
            data = subprocess.check_output(["swift", "-e", """
import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
FileHandle.standardOutput.write(bookmark)
""", str(volume / ".background.tiff")])
            with DSStore.open(str(volume / ".DS_Store"), "r+") as store:
                store["."]["pBBk"] = Bookmark.from_bytes(data)

    dmgbuild.build_dmg(output, "Aza", settings_file=str(Path(__file__).with_name("dmg-settings.py")),
                       defines={"app": app, "background": background}, callback=finalize_background)


if __name__ == "__main__":
    build(*sys.argv[1:])
