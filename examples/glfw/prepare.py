#!/usr/bin/env python3
# Author: GuestAUser (https://github.com/GuestAUser)
# Copyright (c) 2026 GuestAUser
# SPDX-License-Identifier: BSD-2-Clause

"""Fetch verified source archives and build a local, null-only GLFW 3.4."""

import argparse
import hashlib
import json
import pathlib
import shlex
import shutil
import subprocess
import tarfile
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / ".artifacts/maintainer/glfw"
SOURCES = (
    (
        "BindBC/bindbc-glfw",
        "76a8ded72aa5a6f9b275b4df0f7046a5dceb8cb6",
        "c83e9dcfa21a0a91007dc8288ae5897509a280044e38db5fe74b803d64546770",
    ),
    (
        "glfw/glfw",
        "7b6aead9fb88b3623e3b3725ebb42670cbe4c579",
        "169d49096e339caabbc12e1762273c5cb9130a535a282ba46cf5c14ab6e55694",
    ),
)


def run_logged(arguments, name):
    result = subprocess.run(arguments, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log = ARTIFACTS / name
    log.write_text("$ " + shlex.join(map(str, arguments)) + "\n" + result.stdout)

    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}")

    return result.stdout

def prepare(cc="cc"):
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    provenance = []
    extracted = []

    for repository, revision, expected_hash in SOURCES:
        project = repository.split("/")[1]
        url = f"https://codeload.github.com/{repository}/tar.gz/{revision}"
        archive = ARTIFACTS / f"{project}-{revision}.tar.gz"

        if not archive.exists():
            with urllib.request.urlopen(url, timeout=60) as response:
                archive.write_bytes(response.read())

        actual_hash = hashlib.sha256(archive.read_bytes()).hexdigest()

        if actual_hash != expected_hash:
            raise RuntimeError(f"SHA-256 mismatch for {archive}: {actual_hash}")

        directory = ARTIFACTS / f"{project}-{revision}"

        if directory.is_symlink():
            raise RuntimeError(f"Refusing to replace symlinked source directory: {directory}")

        if directory.exists():
            shutil.rmtree(directory)

        with tarfile.open(archive, "r:gz") as source:
            source.extractall(ARTIFACTS, filter="data")

        extracted.append(directory)
        provenance.append({
            "repository": f"https://github.com/{repository}",
            "revision": revision,
            "archive": str(archive.relative_to(ROOT)),
            "url": url,
            "sha256": actual_hash,
            "source": str(directory.relative_to(ROOT)),
        })

    binding, library = extracted
    build = ARTIFACTS / "glfw-build"
    configure = [
        "cmake", "-S", str(library), "-B", str(build), "-G", "Ninja",
        f"-DCMAKE_C_COMPILER={cc}", "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=OFF", "-DGLFW_BUILD_X11=OFF",
        "-DGLFW_BUILD_WAYLAND=OFF", "-DGLFW_BUILD_EXAMPLES=OFF",
        "-DGLFW_BUILD_TESTS=OFF", "-DGLFW_BUILD_DOCS=OFF", "-DGLFW_INSTALL=OFF",
    ]
    run_logged(configure, "cmake-configure.log")
    run_logged(["cmake", "--build", str(build)], "cmake-build.log")

    archive = build / "src/libglfw3.a"
    metadata = {
        "sources": provenance,
        "configure": configure,
        "library": str(archive.relative_to(ROOT)),
        "librarySha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "cCompiler": run_logged([cc, "--version"], "c-compiler.log").splitlines()[0],
        "cmake": run_logged(["cmake", "--version"], "cmake-version.log").splitlines()[0],
        "ninja": run_logged(["ninja", "--version"], "ninja-version.log").strip(),
    }
    (ARTIFACTS / "provenance.json").write_text(json.dumps(metadata, indent=4) + "\n")

    return binding, library, archive

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default="cc", help="C compiler executable")
    arguments = parser.parse_args()
    binding, library, archive = prepare(arguments.cc)
    print(f"BindBC source: {binding}")
    print(f"GLFW source: {library}")
    print(f"Null-only static library: {archive}")
    print(f"Build evidence: {ARTIFACTS}")

if __name__ == "__main__":
    main()
