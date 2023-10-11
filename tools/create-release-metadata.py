#!/usr/bin/env python3

import argparse
import os
from datetime import datetime


def find_file_checksums(release_path):
    files = []

    checksums_path = f"{release_path}/SHA512-SUMS.txt"
    with open(checksums_path, 'r') as checksums:
        for line in checksums:
            split_line = line.split("  ")
            files.append({
                "filename": split_line[1].strip(),
                "checksum": split_line[0].strip()
            })

    return files


def generate_file(version_version: str, version_status: str, git_reference: str):
    # Open the file for writing.

    basedir = os.environ.get("basedir")
    buildsdir = os.environ.get('buildsdir')

    output_path = f"{buildsdir}/releases/godot-{version_version}-{version_status}.json"
    with open(output_path, 'w') as f:
        release_name = version_version
        commit_hash = git_reference
        if version_status == "stable":
            commit_hash = f"{version_version}-stable"
        else:
            release_name = f"{version_version}-{version_status}"

        # Start writing the file with basic meta information.
        f.write(
            f'{{\n'
            f'    "name": "{release_name}",\n'
            f'    "version": "{version_version}",\n'
            f'    "status": "{version_status}",\n'
            f'    "release_date": {int(datetime.now().timestamp())},\n'
            f'    "git_reference": "{commit_hash}",\n'
            f'\n'
            f'    "files": [\n'
        )

        # Generate the list of files.

        release_folder = f"{basedir}/releases/{version_version}-{version_status}"
        standard_files = find_file_checksums(f"{release_folder}")
        mono_files = find_file_checksums(f"{release_folder}/mono")

        for i, file in enumerate(standard_files):
            f.write(
                f'        {{\n'
                f'            "filename": "{file["filename"]}",\n'
                f'            "checksum": "{file["checksum"]}"\n'
                f'        }}{"" if i == len(standard_files) - 1 and len(mono_files) == 0 else ","}\n'
            )

        for i, file in enumerate(mono_files):
            f.write(
                f'        {{\n'
                f'            "filename": "{file["filename"]}",\n'
                f'            "checksum": "{file["checksum"]}"\n'
                f'        }}{"" if i == len(mono_files) - 1 else ","}\n'
            )

        # Finish the file.
        f.write(
            f'    ]\n'
            f'}}\n'
        )

        print(f"Written release metadata to '{output_path}'.")


def main() -> None:
    if os.environ.get("basedir") == "" or os.environ.get("buildsdir") == "":
        print("Failed to create release metadata: Missing 'basedir' (godot-build-scripts) and 'buildsdir' (godot-builds) environment variables.\n")
        exit(1)

    parser = argparse.ArgumentParser()
    parser.add_argument("-v", "--version", default="", help="Godot version in the major.minor.patch format (patch should be omitted for major and minor releases).")
    parser.add_argument("-f", "--flavor", default="stable", help="Release flavor, e.g. dev, alpha, beta, rc, stable (defaults to stable).")
    parser.add_argument("-g", "--git", default="", help="Git commit hash tagged for this release.")
    args = parser.parse_args()

    if args.version == "" or args.git == "":
        print("Failed to create release metadata: Godot version and git hash cannot be empty.\n")
        parser.print_help()
        exit(1)

    release_version = args.version
    release_flavor = args.flavor
    if release_flavor == "":
        release_flavor = "stable"

    generate_file(release_version, release_flavor, args.git)


if __name__ == "__main__":
    main()
