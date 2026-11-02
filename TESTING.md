# User acceptance checks — 1.2.0

This build is ready for a controlled user trial. Earlier builds have been reported working by the user. The new concurrency, throughput and ETA behavior still needs testing with a real account, source drive and connection. Start with a few copied recordings. Keep your original recordings.

## Where the installer is

After `bash scripts/distribute.sh`, the repository contains:

- `dist/Media-Archive-Cloud-Uploader.dmg` — drag-to-Applications installer.
- `dist/Media Archive Cloud Uploader.app` — the application.
- `dist/Media-Archive-Cloud-Uploader-app.zip` — alternative container.
- `dist/SHA256SUMS.txt` — container checksums.

The `dist` directory is local and Git-ignored. Cloning or pulling the source from GitHub does not download the installer. Building requires Xcode; using the built app does not.

Version 1.2.0 was built separately in `dist/1.2.0/` so the existing installer and running app could remain untouched. The normal build script defaults to `dist`; set `DIST_DIR` to isolate a build.

## Upgrade without interrupting the current job

Let the old app finish, or click Cancel and wait for it to stop, then quit. Install the new app only after quitting. Keep the same bucket/source/prefix; do not sign out merely to update. The new build reads the same settings, Keychain and checkpoint formats. No new Google scopes are requested.

## Prepare once

1. Open the DMG and drag the app to Applications. Open it there. This test build is ad-hoc signed and **not notarized**; for a trusted copy, use macOS’s per-app Open Anyway option if offered. Do not disable system security globally.
2. Click **Sign in with Google**. If this Mac has no app configuration, follow the setup sheet to choose a **Desktop app OAuth client JSON**, not a service-account key. Then sign in in your browser. Existing 1.0.1 users should sign out and sign back in to grant the additional read-only project discovery scope.
3. Select the intended **Destination bucket**. Confirm the visible name. If automatic discovery fails, check Cloud Resource Manager API enablement and project/bucket listing permissions; use **Can’t find your bucket?** to search a project ID or enter a known bucket name. Do not assume an empty list means no accessible buckets exist.
4. No `.env` import is required. The app saves choices privately on this Mac. Your older local `.env` remains untouched; explicit import is still available under Setup → Advanced.

## Test in this order

1. **Preview:** Choose a small folder containing a FLAC, WAV or MP3 plus a REAPER/non-audio file. Click Preview (dry run). Verify the destination and eligible files. Confirm that the unwanted file is excluded; export the report. Preview must create no cloud objects.
2. **Small upload:** Prefer a disposable test bucket configured locally. If using the archive bucket, choose a uniquely named test folder and temporarily enable Include selected folder name to isolate the test objects. Inspect the displayed destination before starting. Click Start directly without first running Preview; confirm that scanning/checking proceeds into upload. Confirm the results in Google Cloud. Successful uploads must show checksum verification.
3. **Repeat:** Preview and upload the same folder again. Existing filenames must be skipped; their cloud generations must stay unchanged. Skipping means the name exists, not that existing content was revalidated.
4. **Cancel/resume:** Use a larger copied recording. Wait until the status says Uploading, then Cancel. Retry / Resume should finish without replacing completed objects. Repeat after quitting and reopening; reselect the same folder and prefix setting.
5. **Source changed:** Preview a copied file, edit or replace that copy, then upload. The app must refuse the changed file and ask for a fresh preview.
6. **Report:** Export the final report and check errors and scan issues, not just the completion count. A folder containing only excluded files should also allow report export.

Restore Include selected folder name to **off** for the original contents-at-bucket-root workflow when finished testing. The app never deletes test objects; any cleanup is an administrator decision.

## Parallel transfer and statistics checks

- Use several large copied recordings so transfers last long enough to measure. Compare 1, 2 and 4 workers under the same conditions; use distinct destination names so completed-file skips do not invalidate the comparison. No benchmark against the live archive has been run by the developer.
- Confirm the active file count never exceeds the selected limit. Settings should survive restart, and the limit cannot change mid-run.
- Watch aggregate speed and ETA. The first estimate appears after data is acknowledged; speed should update while a chunk is still being sent. Skipped files and old resume offsets must not cause a speed spike. A stalled/retrying batch must not keep showing a stale ETA.
- Cancel while multiple files are active, wait for the app to become idle, and retry. Completed files must remain intact; remaining files resume or restart safely. Repeat after quitting/reopening.
- Interrupt the connection while multiple files are active. Check recovery and per-file errors. A global login/permission failure must stop the batch; ordinary file errors should allow other files to finish.
- Verify Preview still uploads nothing. Verify unreadable paths or failed cloud checks stop automatic Start and provide an exportable report.

## New setup checks

- Restart after choosing a destination/folder/prefix. Confirm they are remembered for the same account and no upload starts automatically.
- Sign out or switch accounts. Confirm the destination clears and a fresh selection is required.
- Choose individual files with another unselected audio file beside them. Preview must include only the selected valid audio files, at the bucket root by filename. Choose files from one folder at a time; use Choose folder for trees.
- Check Refresh, a project with denied bucket-list access, and cancellation during discovery. Errors should be visible; other discoverable buckets should still appear.
- Test Finder installation on the engineer’s Mac, including the guided first-login sheet. Using the packaged app requires no Xcode or Google CLI.

## Stop and report

Stop the trial for a wrong destination, an overwrite, an unexpected login prompt, a checksum error, a crash, or unreported missing files. Keep the exported report and the exact visible error. Reports include local paths and cloud object names; share them privately and do not commit them to the public repo. Never share OAuth JSON, tokens or resumable session URLs.

Before an engineer relies on it unattended, complete the live tests above and test on the engineer’s Mac. Developer ID signing/notarization and clean-machine installation checks are still needed for routine distribution. See RELEASE.md and REVIEW.md.
