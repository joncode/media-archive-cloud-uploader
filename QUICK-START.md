# Media Archive Cloud Uploader — engineer’s guide

For the first trial, follow TESTING.md before attempting a large archive.

Requires macOS 13 Ventura or later. The app supports Apple silicon and Intel Macs.

If upgrading from Bisco Archive Uploader, quit the old app and use **Media Archive Cloud Uploader** after installation. Existing local settings and Keychain entries are retained; the earlier app copy can be removed from Applications once the new one is working.

## Install and connect

1. Open the disk image and drag **Media Archive Cloud Uploader** to **Applications**. Run it from Applications.
2. Click **Sign in with Google**. On first use, the app guides you through choosing the Desktop app OAuth JSON supplied by your archive administrator. Then sign in with your own account in the browser.
3. Choose your destination from **Destination bucket**. The list includes buckets Google allows this account to see. If one is missing, click **Can’t find your bucket?** to search a project or enter a known bucket name.
4. Your destination and last source folder are remembered privately on this Mac. You do not need a `.env` file. Signing out clears the destination selection.

The supplied development build is locally signed, **not Developer ID signed or notarized**. macOS may block a downloaded copy. For a build you trust, use Apple’s per-app **System Settings → Privacy & Security → Open Anyway** option if offered. Do not disable Gatekeeper systemwide. For routine distribution, ask the maintainer for a Developer ID signed and notarized release.

## Upload a show

1. Finish recording and editing the source files. Connect the drive and click **Choose folder…** for a recursive archive, or **Choose files…** for individual recordings from one folder. Explicitly selected files go directly to the bucket root by filename; only those files are scanned.
2. Leave **Include selected folder name** off to match the original workflow:
   - Select a folder named `Archive`.
   - `Archive/Show/01.flac` becomes `Show/01.flac` in the configured bucket.
   - Turning the switch on adds `Archive/` before `Show/01.flac`.
3. Click **Preview (dry run)**. Review the destination paths and files marked “Will skip — exists.” Preview does not upload anything.
4. Click **Start upload**. Keep the Mac awake and connected. The app prevents idle system sleep during uploads, but cannot prevent closing the laptop or unplugging a drive.
5. Check the completion message. Select any failed row for details. **Export report…** includes excluded files and scan problems.

Only readable FLAC, WAV and MP3 audio containers are included. AppleDouble `._` files, hidden paths, REAPER files, symbolic links, empty files and unsupported audio containers are excluded. Container checking is not a full decode or a guarantee that a recording sounds correct.

Existing cloud objects are skipped **by name**, regardless of their size or content. They are not replaced, repaired or compared for audio equivalence. Nothing is deleted locally or from the bucket.

## Stop, retry and resume

**Cancel** stops the active work and preserves resume information. A request already accepted by Google may finish as cancellation arrives. **Retry / Resume** checks Google’s saved offset and continues unfinished files. Progress updates after each acknowledged chunk, so it can sit still on a slow connection or during the initial integrity check.

After quitting or restarting the Mac, review the remembered folder and prefix setting, preview, and start again. Reselect individual files if you used Choose files. Completed files are skipped; unfinished uploads can resume. Expired sessions restart safely. Signing out or changing Google accounts clears saved resume sessions on this Mac. Source files must remain unchanged.

For “access denied,” have the administrator check the account and bucket permissions. For “source changed,” finish editing and preview again. If a file’s completion cannot be verified, ask the administrator to inspect it; do not assume that retrying verifies an existing object.

**Sign out** removes this app’s saved login and resume data from the Mac. To revoke Google’s grant too, use **Setup → Google account permissions…**.
