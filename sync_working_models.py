"""
Mirrors Working Models photos from Kinetix into a local `working_models/`
folder, so Deep-Live-Cam's "Select a face" file picker can browse straight
into it -- no Google Drive account, no manual download, ever.

Run standalone (`python sync_working_models.py`) or let launch.bat call it
automatically before starting the app. Safe to run repeatedly: existing
files are skipped, only new photos are downloaded. Kinetix is the source of
truth -- a photo deleted or renamed there is deleted or renamed here too, on
the NEXT sync (this only prunes files matching our own naming convention,
`<8-char-id>_<name>`; anything else found in working_models/ was not put
there by this script and is left alone).

Config lives in working_models_sync_config.json -- gitignored (this repo
is public), copy working_models_sync_config.example.json and fill in the
real api_key. Ask di/RJ for the key rather than committing it.
"""

import json
import os
import re
import urllib.request
import urllib.error

CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "working_models_sync_config.json")
OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "working_models")

# Files we manage are named "<first-8-chars-of-photo-id>_<original-filename>".
# Only files matching this get pruned -- anything else in working_models/
# (someone manually dropping in a face for their own convenience) was never
# ours to begin with, so a Kinetix-side deletion cannot touch it.
_MANAGED_FILENAME = re.compile(r'^[0-9a-fA-F]{8}_.+')


def load_config():
    with open(CONFIG_PATH, "r") as f:
        return json.load(f)


def safe_path_component(name: str) -> str:
    return re.sub(r'[^a-zA-Z0-9._ -]', '_', name).strip() or "unnamed"


def fetch_photos(api_url: str, api_key: str):
    req = urllib.request.Request(
        f"{api_url}/working-models-sync/photos",
        headers={"Authorization": f"Bearer {api_key}"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    if not body.get("success"):
        raise RuntimeError(f"Sync API returned success=false: {body}")
    return body["data"]


def download(url: str, dest_path: str):
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=30) as resp, open(dest_path, "wb") as out:
        out.write(resp.read())


def sync(status=print) -> str:
    """
    Runs the sync and returns a one-line summary. `status` is called with
    progress messages as it goes -- pass ui.update_status for a UI-thread
    -safe callback, or leave as print for the CLI/launch.bat case.
    """
    try:
        config = load_config()
    except FileNotFoundError:
        msg = f"Missing {CONFIG_PATH} -- can't sync Working Models."
        status(msg)
        return msg

    api_url = config["api_url"]
    api_key = config["api_key"]

    status("Syncing Working Models from Kinetix...")
    try:
        photos = fetch_photos(api_url, api_key)
    except (urllib.error.URLError, urllib.error.HTTPError, RuntimeError) as e:
        msg = f"Working Models sync failed ({e}) -- continuing without it."
        status(msg)
        return msg

    downloaded, skipped, failed = 0, 0, 0
    expected_paths = set()
    for photo in photos:
        folder_components = [safe_path_component(part) for part in photo["folderPath"].split("/")]
        folder_dir = os.path.join(OUTPUT_DIR, *folder_components)
        os.makedirs(folder_dir, exist_ok=True)

        filename = f"{photo['id'][:8]}_{safe_path_component(photo['originalFilename'] or 'photo.jpg')}"
        dest_path = os.path.join(folder_dir, filename)

        if os.path.exists(dest_path):
            skipped += 1
            expected_paths.add(dest_path)
            continue

        expected_paths.add(dest_path)

        try:
            download(photo["url"], dest_path)
            downloaded += 1
        except (urllib.error.URLError, urllib.error.HTTPError) as e:
            status(f"  Failed to download {photo['originalFilename']}: {e}")
            failed += 1

    removed = _prune(expected_paths, status)

    summary = (f"Working Models sync: {downloaded} new, {skipped} already present, "
               f"{removed} removed, {failed} failed. ({len(photos)} total on Kinetix)")
    status(summary)
    return summary


def _prune(expected_paths: set, status) -> int:
    """
    Delete any file under OUTPUT_DIR that (a) matches our own naming
    convention and (b) is not in `expected_paths` -- i.e. it belonged to a
    photo that Kinetix no longer lists, because it was deleted OR renamed
    OR moved to a different folder there (a rename shows up here as one of
    each: the old name is no longer expected, so it prunes; the new name
    was not on disk yet, so it downloads).

    Then removes any folder left empty by that, walking bottom-up so a
    folder emptied by removing its last subfolder is cleaned up too.
    """
    if not os.path.isdir(OUTPUT_DIR):
        return 0

    removed = 0
    for root, _dirs, files in os.walk(OUTPUT_DIR):
        for filename in files:
            if not _MANAGED_FILENAME.match(filename):
                continue
            full_path = os.path.join(root, filename)
            if full_path not in expected_paths:
                try:
                    os.remove(full_path)
                    removed += 1
                except OSError as e:
                    status(f"  Failed to remove {full_path}: {e}")

    for root, dirs, files in os.walk(OUTPUT_DIR, topdown=False):
        if root == OUTPUT_DIR:
            continue
        if not dirs and not files:
            try:
                os.rmdir(root)
            except OSError:
                pass  # not empty after all, or a permissions hiccup -- harmless either way

    return removed


if __name__ == "__main__":
    sync()
