"""
Pulls Working Models photos from Kinetix into a local `working_models/`
folder, mirroring its folder structure, so Deep-Live-Cam's "Select a face"
file picker can browse straight into it -- no Google Drive account, no
manual download, ever.

Run standalone (`python sync_working_models.py`) or let launch.bat call it
automatically before starting the app. Safe to run repeatedly: existing
files are skipped, only new photos are downloaded (additive only -- it does
not delete local files for photos removed on the Kinetix side).

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
    for photo in photos:
        folder_components = [safe_path_component(part) for part in photo["folderPath"].split("/")]
        folder_dir = os.path.join(OUTPUT_DIR, *folder_components)
        os.makedirs(folder_dir, exist_ok=True)

        filename = f"{photo['id'][:8]}_{safe_path_component(photo['originalFilename'] or 'photo.jpg')}"
        dest_path = os.path.join(folder_dir, filename)

        if os.path.exists(dest_path):
            skipped += 1
            continue

        try:
            download(photo["url"], dest_path)
            downloaded += 1
        except (urllib.error.URLError, urllib.error.HTTPError) as e:
            status(f"  Failed to download {photo['originalFilename']}: {e}")
            failed += 1

    summary = (f"Working Models sync: {downloaded} new, {skipped} already present, "
               f"{failed} failed. ({len(photos)} total on Kinetix)")
    status(summary)
    return summary


if __name__ == "__main__":
    sync()
