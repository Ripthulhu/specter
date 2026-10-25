"""Read-only helper smoke checks on an explicitly selected Android device."""
import argparse
import json
import os
import pathlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--serial", required=True)
parser.add_argument("--dex", type=pathlib.Path, required=True)
parser.add_argument("--adb", default="adb")
args = parser.parse_args()
directory = f"/data/local/tmp/specter-helper-test-{os.getpid()}"


def adb(*command, data=None):
    return subprocess.run([args.adb, "-s", args.serial, *command], input=data,
                          capture_output=True, timeout=30)


def helper(name, arguments, data=None):
    return adb("shell", f"CLASSPATH={directory}/classes.dex app_process / com.dpejoh.specter.{name} {arguments}", data=data)


try:
    assert adb("shell", f"mkdir {directory}").returncode == 0
    assert adb("push", str(args.dex), f"{directory}/classes.dex").returncode == 0
    sha = "a" * 64
    release = {"name": "Release.zip", "digest": "sha256:" + sha,
               "browser_download_url": "https://github.com/owner/repo/releases/download/v1/Release.zip"}
    debug = {**release, "name": "Debug.zip",
             "browser_download_url": "https://github.com/owner/repo/releases/download/v1/Debug.zip"}
    cases = [
        ([debug, release], release),
        ([debug], debug),
        ([{**release, "digest": None}], None),
        ([{**release, "digest": "sha256:abc"}], None),
        ([{key: value for key, value in release.items() if key != "digest"}], None),
        ([{**release, "browser_download_url": "https://github.com/other/repo/releases/download/v1/Release.zip"}], None),
        ([{**release, "browser_download_url": "http://github.com/owner/repo/releases/download/v1/Release.zip"}], None),
        ([{**release, "browser_download_url": release["browser_download_url"] + ".txt"}], None),
    ]
    for assets, expected in cases:
        for indent in [None, 2]:
            result = helper("ReleaseAsset", "owner/repo", json.dumps({"assets": assets}, indent=indent).encode())
            assert (result.returncode == 0) == (expected is not None), result.stderr.decode(errors="replace")
            if expected:
                assert result.stdout.decode().strip() == expected["browser_download_url"] + "|" + sha
    assert helper("ReleaseAsset", "owner/repo", b"invalid json").returncode != 0
    result = helper("HttpsDownload", f"https://api.github.com/repos/Ripthulhu/specter {directory}/payload Specter/test")
    assert result.returncode == 0, result.stderr.decode(errors="replace")
    payload = adb("shell", f"cat {directory}/payload")
    assert json.loads(payload.stdout)["full_name"] == "Ripthulhu/specter"
    result = helper("HttpsDownload", f"https://self-signed.badssl.com/ {directory}/payload Specter/test")
    assert result.returncode != 0
    assert any(term in result.stderr.decode().lower() for term in ["certificate", "sslhandshake", "certpath"]), result.stderr.decode(errors="replace")
    assert adb("shell", f"test ! -e {directory}/payload").returncode == 0
    print("19 Android helper checks passed; installed modules unchanged.")
finally:
    adb("shell", f"rm -f {directory}/classes.dex {directory}/payload; rmdir {directory}")
