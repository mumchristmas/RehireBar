#!/usr/bin/env python3
"""Exercise Sparkle with disposable apps and test keys on a logged-in Mac."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
SDK = ROOT / ".build/artifacts/sparkle/Sparkle"
FRAMEWORK = SDK / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True, **kwargs)


class QuietHTTPHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main():
    if not FRAMEWORK.is_dir():
        raise RuntimeError("Run swift package resolve first.")
    os.environ.setdefault("DEVELOPER_DIR", run(["xcode-select", "-p"]).stdout.strip())
    os.environ["SDKROOT"] = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).stdout.strip()
    output = ROOT / "artifacts/update-tests"
    output.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix="run-", dir=output))
    key = folder / "test-key.private"
    binary = folder / "UpdateFixture"
    results = []
    try:
        public_key = run(["xcrun", "swift", ROOT / "scripts/test-support/make-update-test-key.swift", key]).stdout.strip()
        run(["xcrun", "clang", "-fobjc-arc", "-mmacosx-version-min=15.0", "-framework", "AppKit",
             "-framework", "Sparkle", "-F", FRAMEWORK.parent,
             "-Wl,-rpath,@executable_path/../Frameworks", ROOT / "scripts/test-support/UpdateFixture.m", "-o", binary])
        for case in ("install", "up-to-date", "downgrade", "tampered-feed", "tampered-archive"):
            directory = folder / case
            feed = directory / "feed"
            feed.mkdir(parents=True)
            server = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHTTPHandler, directory=str(feed)))
            threading.Thread(target=server.serve_forever, daemon=True).start()
            address = f"http://127.0.0.1:{server.server_port}"
            bundle_id = "org.rehirebar.update-fixture." + uuid.uuid4().hex
            outcome = directory / "outcome.json"
            process = None
            try:
                old_version = "2" if case == "up-to-date" else "3" if case == "downgrade" else "1"

                def make_app(destination, version, replacement):
                    contents = destination / "Contents"
                    (contents / "MacOS").mkdir(parents=True)
                    (contents / "Frameworks").mkdir()
                    shutil.copy2(binary, contents / "MacOS/UpdateFixture")
                    run(["ditto", "--norsrc", FRAMEWORK, contents / "Frameworks/Sparkle.framework"])
                    metadata = {
                        "CFBundleName": "RehireBar Update Fixture", "CFBundleIdentifier": bundle_id,
                        "CFBundleExecutable": "UpdateFixture", "CFBundlePackageType": "APPL",
                        "CFBundleShortVersionString": "0.0." + version, "CFBundleVersion": version,
                        "LSMinimumSystemVersion": "15.0", "LSUIElement": True,
                        "NSPrincipalClass": "NSApplication", "SUPublicEDKey": public_key,
                        "SUFeedURL": address + "/appcast.xml", "SUEnableAutomaticChecks": False,
                        "SUAutomaticallyUpdate": False, "SUAllowsAutomaticUpdates": False,
                        "SUEnableSystemProfiling": False, "SUVerifyUpdateBeforeExtraction": True,
                        "SURequireSignedFeed": True, "SUSignedFeedFailureExpirationInterval": 0,
                        # Loopback HTTP is confined to these disposable fixtures.
                        "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
                        "RBTestOutcome": str(outcome), "RBTestReplacement": replacement,
                    }
                    (contents / "Info.plist").write_bytes(plistlib.dumps(metadata))
                    run(["xattr", "-cr", destination])
                    run(["codesign", "--force", "--sign", "-", destination])

                old = directory / "installed/UpdateFixture.app"
                new = directory / "new/UpdateFixture.app"
                make_app(old, old_version, False)
                make_app(new, "2", True)
                archive = feed / "UpdateFixture-2.zip"
                run(["ditto", "-c", "-k", "--norsrc", "--keepParent", new, archive])
                run([SDK / "bin/generate_appcast", "--ed-key-file", key, "--maximum-deltas", "0",
                     "--download-url-prefix", address + "/", "-o", feed / "appcast.xml", feed], timeout=30)
                run([SDK / "bin/sign_update", "--ed-key-file", key, "--verify", feed / "appcast.xml"])
                if case == "tampered-feed":
                    text = (feed / "appcast.xml").read_text()
                    assert "<title>" in text
                    (feed / "appcast.xml").write_text(text.replace("<title>", "<title>changed ", 1))
                elif case == "tampered-archive":
                    data = bytearray(archive.read_bytes())
                    data[len(data) // 2] ^= 1
                    archive.write_bytes(data)

                with (directory / "process.log").open("wb") as log:
                    process = subprocess.Popen([str(old / "Contents/MacOS/UpdateFixture")], stdout=log, stderr=log)
                    deadline = time.monotonic() + 60
                    while time.monotonic() < deadline and not outcome.exists():
                        time.sleep(0.1)
                    if not outcome.exists():
                        raise RuntimeError(f"{case}: no outcome; inspect {directory}")
                result = json.loads(outcome.read_text())
                installed = plistlib.loads((old / "Contents/Info.plist").read_bytes())
                expected = "installed-and-relaunched" if case == "install" else "no-update" if case in ("up-to-date", "downgrade") else "rejected"
                assert result["kind"] == expected, (case, result)
                assert installed["CFBundleVersion"] == ("2" if case == "install" else old_version), (case, installed)
                if case.startswith("tampered"):
                    assert "installing" not in result["events"], result
                    assert result["errorDomain"] == "SUSparkleErrorDomain", result
                    assert result["errorCode"] == (1000 if case == "tampered-feed" else 4005), result
                    assert ("found" in result["events"]) == (case == "tampered-archive"), result
                results.append({"case": case, "result": result, "installedBuild": installed["CFBundleVersion"]})
                (folder / "results.json").write_text(json.dumps(results, indent=2))
                print(case + ": passed", flush=True)
            finally:
                if process and process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                server.shutdown()
                server.server_close()
                subprocess.run(["defaults", "delete", bundle_id], capture_output=True)
    finally:
        key.unlink(missing_ok=True)
    print("Results: " + str(folder / "results.json"), flush=True)


if __name__ == "__main__":
    main()
