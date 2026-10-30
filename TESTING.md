# First user test — 1.0.1

This build is ready for a controlled user trial. Automated tests and a code review have run; a real Google sign-in/upload still needs to be tested. Start with a few copied recordings. Keep your original recordings.

## Where the installer is

After `bash scripts/distribute.sh`, the repository contains:

- `dist/Bisco-Archive-Uploader.dmg` — drag-to-Applications installer.
- `dist/Bisco Archive Uploader.app` — the application.
- `dist/Bisco-Archive-Uploader-app.zip` — alternative container.
- `dist/SHA256SUMS.txt` — container checksums.

The `dist` directory is local and Git-ignored. Cloning or pulling the source from GitHub does not download the installer. Building requires Xcode; using the built app does not.

## Prepare once

1. Open the DMG and drag the app to Applications. Open it there. This test build is ad-hoc signed and **not notarized**; for a trusted copy, use macOS’s per-app Open Anyway option if offered. Do not disable system security globally.
2. In the app, choose **Setup → Import environment configuration (.env)…** and select your local repository `.env`. The picker shows hidden files. Your real values stay local; the public `.env.example` is empty.
3. Choose **Setup → Import Google client JSON…**. This is a **Desktop app OAuth client** configuration from your Google Cloud project, not a service-account key. A Google Cloud account alone does not replace this app configuration. README.md explains how the administrator creates it and enables consent for the test user.
4. Click **Sign in with Google**, complete browser consent, return to the app and verify the account email. The account needs create/get access to the destination bucket. If Google denies consent or bucket access, stop and correct setup.

## Test in this order

1. **Preview:** Choose a small folder containing a FLAC, WAV or MP3 plus a REAPER/non-audio file. Click Preview (dry run). Verify the destination and eligible files. Confirm that the unwanted file is excluded; export the report. Preview must create no cloud objects.
2. **Small upload:** Prefer a disposable test bucket configured locally. If using the archive bucket, choose a uniquely named test folder and temporarily enable Include selected folder name to isolate the test objects. Inspect the displayed destination before starting. Upload the small files and confirm the results in Google Cloud. Successful uploads must show checksum verification.
3. **Repeat:** Preview and upload the same folder again. Existing filenames must be skipped; their cloud generations must stay unchanged. Skipping means the name exists, not that existing content was revalidated.
4. **Cancel/resume:** Use a larger copied recording. Wait until the status says Uploading, then Cancel. Retry / Resume should finish without replacing completed objects. Repeat after quitting and reopening; reselect the same folder and prefix setting.
5. **Source changed:** Preview a copied file, edit or replace that copy, then upload. The app must refuse the changed file and ask for a fresh preview.
6. **Report:** Export the final report and check errors and scan issues, not just the completion count. A folder containing only excluded files should also allow report export.

Restore Include selected folder name to **off** for the original contents-at-bucket-root workflow when finished testing. The app never deletes test objects; any cleanup is an administrator decision.

## Stop and report

Stop the trial for a wrong destination, an overwrite, an unexpected login prompt, a checksum error, a crash, or unreported missing files. Keep the exported report and the exact visible error. Reports include local paths and cloud object names; share them privately and do not commit them to the public repo. Never share OAuth JSON, tokens or resumable session URLs.

Before an engineer relies on it unattended, complete the live tests above and test on the engineer’s Mac. Developer ID signing/notarization and clean-machine installation checks are still needed for routine distribution. See RELEASE.md and REVIEW.md.
