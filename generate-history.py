import json
import os
import subprocess
from datetime import datetime


releases = []

# Read JSON files and generate correct release history.

releases_path = "./releases"

dir_contents = os.listdir(releases_path)
for filename in dir_contents:
    filepath = os.path.join(releases_path, filename)
    if not os.path.isfile(filepath):
        continue

    with open(filepath, 'r') as json_data:
        release_data = json.load(json_data)

    print(f"Reading release '{release_data['name']}' data.")
    releases.append({
        "file": filepath,
        "data": release_data
    })

# Sort by release date so we can create commits in order
releases.sort(key=lambda x: x['data']['release_date'])

# Generate a commit for each release, spoof the commit date to
# match the release date.

for release_data in releases:
    commit_datetime = datetime.fromtimestamp(release_data['data']['release_date'])
    # Thu, 07 Apr 2005 22:13:13 +0200
    commit_date = commit_datetime.strftime('%a, %d %b %Y %H:%M:%S +0000')
    release_tag = f"{release_data['data']['version']}-{release_data['data']['status']}"

    cmd_add_file = f"git add {release_data['file']}"
    cmd_commit_release = f"git commit -m \"Add Godot {release_tag}\""
    cmd_amend_time = f"git commit --amend --no-edit --date \"{commit_date}\""
    cmd_tag_release = f"git tag {release_tag}"

    extra_env = os.environ.copy()
    extra_env['GIT_COMMITTER_DATE'] = commit_date

    subprocess.run(cmd_add_file)
    subprocess.run(cmd_commit_release, env=extra_env)
    subprocess.run(cmd_amend_time, env=extra_env)
    subprocess.run(cmd_tag_release, env=extra_env)

    print(f"Committed release '{release_data['data']['name']}'.")
