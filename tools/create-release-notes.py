#!/usr/bin/env python3

import argparse
import os


def get_version_name(version_version: str, version_status: str) -> str:
    version_name = version_version

    if version_status == "stable":
        return version_name

    version_name += " "
    if version_status.startswith("rc"):
        version_name += f"RC {version_status.removeprefix('rc')}"
    elif version_status.startswith("beta"):
        version_name += f"beta {version_status.removeprefix('beta')}"
    elif version_status.startswith("alpha"):
        version_name += f"alpha {version_status.removeprefix('alpha')}"
    elif version_status.startswith("dev"):
        version_name += f"dev {version_status.removeprefix('dev')}"
    else:
        version_name += version_status

    return version_name


def get_version_description(version_version: str, version_status: str, version_flavor: str) -> str:
    version_description = ""

    if version_status == "stable":
        if version_flavor == "major":
            version_description = "a major release introducing new features and considerable changes to core systems. **Major version releases contain compatibility breaking changes.**"
        elif version_flavor == "minor":
            version_description = "a feature release improving upon the previous version in many aspects, such as usability and performance. Feature releases also contain new features, but preserve compatibility with previous releases."
        else:
            version_description = "a maintenance release addressing stability and usability issues, and fixing all sorts of bugs. Maintenance releases are compatible with previous releases and are recommended for adoption."
    else:
        flavor_name = "maintenance"
        if version_flavor == "major":
            flavor_name = "major"
        elif version_flavor == "minor":
            flavor_name = "feature"

        if version_status.startswith("rc"):
            version_description = f"a release candidate for the {version_version} {flavor_name} release. Release candidates focus on finalizing the release and fixing remaining critical bugs."
        elif version_status.startswith("beta"):
            version_description = f"a beta snapshot for the {version_version} {flavor_name} release. Beta snapshots are feature-complete and provided for public beta testing to catch as many bugs as possible ahead of the stable release."
        else: # alphas and devs go here.
            version_description = f"a dev snapshot for the {version_version} {flavor_name} release. Dev snapshots are in-development builds of the engine provided for early testing and feature evaluation while the engine is still being worked on."

    return version_description


def get_release_notes_url(version_version: str, version_status: str, version_flavor: str) -> str:
    release_notes_slug = ""
    version_sluggified = version_version.replace(".", "-")

    if version_status == "stable":
        if version_flavor == "major":
            release_notes_slug = f"major-release-godot-{version_sluggified}"
        elif version_flavor == "minor":
            release_notes_slug = f"feature-release-godot-{version_sluggified}"
        else:
            release_notes_slug = f"maintenance-release-godot-{version_sluggified}"
    else:
        if version_status.startswith("rc"):
            status_sluggified = version_status.removeprefix("rc").replace(".", "-")
            release_notes_slug = f"release-candidate-godot-{version_sluggified}-rc-{status_sluggified}"
        elif version_status.startswith("beta"):
            status_sluggified = version_status.removeprefix("beta").replace(".", "-")
            release_notes_slug = f"dev-snapshot-godot-{version_sluggified}-beta-{status_sluggified}"
        elif version_status.startswith("alpha"):
            status_sluggified = version_status.removeprefix("alpha").replace(".", "-")
            release_notes_slug = f"dev-snapshot-godot-{version_sluggified}-alpha-{status_sluggified}"
        elif version_status.startswith("dev"):
            status_sluggified = version_status.removeprefix("dev").replace(".", "-")
            release_notes_slug = f"dev-snapshot-godot-{version_sluggified}-dev-{status_sluggified}"
        else:
            status_sluggified = version_status.replace(".", "-")
            release_notes_slug = f"dev-snapshot-godot-{version_sluggified}-{status_sluggified}"

    return f"https://godotengine.org/article/{release_notes_slug}/"


def generate_notes(version_version: str, version_status: str, git_reference: str) -> None:
    notes = ""

    version_tag = f"{version_version}-{version_status}"

    version_bits = version_version.split(".")
    version_flavor = "patch"
    if len(version_bits) == 2 and version_bits[1] == "0":
        version_flavor = "major"
    elif len(version_bits) == 2 and version_bits[1] != "0":
        version_flavor = "minor"

    # Add the intro line.

    version_name = get_version_name(version_version, version_status)
    version_description = get_version_description(version_version, version_status, version_flavor)

    notes += f"**Godot {version_name}** is {version_description}\n\n"

    # Link to the bug tracker.

    notes += "Report bugs on GitHub after checking that they haven't been reported:\n"
    notes += "- https://github.com/godotengine/godot/issues\n"
    notes += "\n"

    # Add build information.

    # Only for pre-releases.
    if version_status != "stable":
        commit_hash = git_reference
        notes += f"Built from commit [{commit_hash}](https://github.com/godotengine/godot/commit/{commit_hash}).\n"
        notes += f"To make a custom build which would also be recognized as {version_status}, you should define `GODOT_VERSION_STATUS={version_status}` in your build environment prior to compiling.\n"
        notes += "\n"

    # Add useful links.

    notes += "----\n"
    notes += "\n"

    release_notes_url = get_release_notes_url(version_version, version_status, version_flavor)

    notes += f"- [Release notes]({release_notes_url})\n"

    if version_status == "stable":
        notes += f"- [Complete changelog](https://godotengine.github.io/godot-interactive-changelog/#{version_version})\n"
        notes += f"- [Curated changelog](https://github.com/godotengine/godot/blob/{version_tag}/CHANGELOG.md)\n"
    else:
        notes += f"- [Complete changelog](https://godotengine.github.io/godot-interactive-changelog/#{version_tag})\n"

    notes += "\n----\n\n"

    notes += "- **Download (GitHub):** Expand **Assets** below\n"

    return notes


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("-v", "--version", default="", help="Godot version in the major.minor.patch format (patch should be omitted for major and minor releases).")
    parser.add_argument("-f", "--flavor", default="stable", help="Release flavor, e.g. dev, alpha, beta, rc, stable (defaults to stable).")
    parser.add_argument("-g", "--git", default="", help="Git commit hash tagged for this release.")
    args = parser.parse_args()

    if args.version == "" or args.git == "":
        print("Failed to create release notes: Godot version and git hash cannot be empty.\n")
        parser.print_help()
        exit(1)

    release_version = args.version
    release_flavor = args.flavor
    if release_flavor == "":
        release_flavor = "stable"
    release_tag = f"{release_version}-{release_flavor}"

    release_notes = generate_notes(release_version, release_flavor, args.git)
    release_notes_file = f"./tmp/release-notes-{release_tag}.txt"
    with open(release_notes_file, 'w') as temp_notes:
        temp_notes.write(release_notes)

    print(f"Written release notes to '{release_notes_file}'.")


if __name__ == "__main__":
    main()
