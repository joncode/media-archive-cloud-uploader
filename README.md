# Bisco Archive Uploader

A native SwiftUI macOS app for uploading FOH recordings to a Google Cloud Storage bucket configured locally. The selected folder’s **contents go to the bucket root by default**, as explicitly requested. A visible switch can include the selected folder’s name.

Start with [TESTING.md](TESTING.md) for the first controlled trial and [REVIEW.md](REVIEW.md) for current findings and limits.

Read [QUICK-START.md](QUICK-START.md) for the engineer’s workflow and [RELEASE.md](RELEASE.md) for packaging. [VALIDATION.md](VALIDATION.md) records what was actually tested and what still needs a real account.

## What is implemented

- Google browser login, automatic bucket discovery across visible projects, a destination picker, native folder or individual-file pickers, and private saved selections. No `.env` is needed for normal use.
- Recursive audio-only scan: case-insensitive `.flac`, `.wav`, `.mp3` plus AudioToolbox container/type and nonzero audio-data validation. No symlinks, hidden paths, AppleDouble or REAPER uploads. Excluded paths and unreadable paths appear in the exported report.
- Explicit preview before uploading. Signed-out preview is local; signed-in preview checks cloud metadata with GET requests. It creates no upload sessions.
- Existing objects skipped by name. Every new upload is protected by `ifGenerationMatch=0`, including retries and replacements of expired sessions. A 412 response is a safe skip. A 403 is an error, never “not found.”
- Sequential uploads with bounded 8 MiB chunks, acknowledged-byte progress, per-file status, errors, exported reports, exponential backoff with jitter, cancellation and retry.
- Keychain-persisted resumable session URLs. On restart, the engineer reselects the folder and previews. The app queries the saved server offset instead of guessing how many bytes arrived. Sessions older than six days are restarted, ahead of Google’s one-week expiry.
- SHA-256 binds a saved session to the exact source content; MD5 is supplied as object metadata for server-side transfer validation and checked in the completion response. File identity, size and modification time are also checked while reading.
- No shell execution, runtime package downloads, bundled Python, CLI dependency, service account key, embedded Google client, user credential or analytics.

The app does not change storage class, bucket settings, object ACLs or retention. It inherits the bucket defaults. It does not delete or overwrite objects. Existing same-name objects are not content-verified. A generic audio container check is deliberately conservative: some unusual WAV variants may be excluded and need separate review. Uploads are one file at a time; performance tuning and parallel transfers are future work.

## Choose and remember your destination

Click **Sign in with Google**, choose a bucket from the list, then use **Choose folder…** or **Choose files…**. The first sign-in guides you through importing the administrator’s Desktop app OAuth configuration if this Mac does not have it yet. The app never chooses the first bucket automatically.

Google lists buckets per project. The app discovers active projects through Resource Manager, then lists their buckets with pagination. A project that denies bucket listing produces a visible warning; it is not silently treated as empty. **Can’t find your bucket?** lets you search a project by ID or use a known bucket when your account has bucket-only access. Listing a bucket does not prove upload permission; Preview checks object access before you upload.

Selections are saved to `~/Library/Application Support/Bisco Archive Uploader/settings.json` with owner-only file/directory permissions (600/700). This stores the bucket, project ID when known, account email, last folder and prefix setting. Login credentials and upload sessions stay in Keychain. A saved destination is restored only for the same signed-in account; sign-out or switching accounts clears it. Individual-file selections must be reselected after restarting, to avoid accidentally scanning their entire containing folder.

Folder contents go to the bucket root unless **Include selected folder name** is on. **Choose files…** accepts recordings from one containing folder, maps only those filenames to the bucket root, and disables the folder prefix switch. Use **Choose folder…** for a recursive folder tree. Review destination paths in Preview before starting, especially when switching between file and folder selection.

No production bucket, project, source path, settings file or user credentials are bundled or published.

### Optional advanced environment import

The old `.env` import remains under **Setup → Advanced** for existing installations and managed setups. `BISCO_GCS_BUCKET` sets the bucket; `BISCO_SOURCE_FOLDER` optionally sets an absolute folder path. `BISCO_ENV_FILE` selects a local file for an explicit reload/import. These values are literal, never shell code. Process environment values override the legacy file when importing it. Normal startup uses saved GUI choices; an existing legacy configuration is migrated only if no settings file exists. **Reload environment configuration** explicitly replaces saved GUI choices with the legacy configuration. `scripts/run.sh` no longer requires a `.env`.

The repository’s `.env` remains ignored and is not modified or published. Never include real settings in Git or a release bundle.

## One-time Google setup — archive administrator

1. In your Google Cloud project, enable the Cloud Storage and Cloud Resource Manager APIs if needed. Configure Google Auth Platform branding, audience and data access.
2. Create an OAuth client of type **Desktop app**, then download its JSON. This app accepts the `installed` JSON shape, not a Web client or service account key. Supply the file separately to the engineer, who imports it through Setup. Do not commit it into source or place it in the release bundle.
3. Permit the engineer’s Google account to authorize the app. While an external consent screen is in Testing, add that account as a test user. Testing-mode refresh tokens can expire after seven days; move to the appropriate production/internal configuration and complete any Google verification required for your audience and scopes.
4. Grant bucket access as described below. Run the live acceptance checks in VALIDATION.md before treating the build as production-ready.

Google desktop clients are public clients: their downloaded `client_secret`, when present, is not a durable confidential secret. This implementation nonetheless imports the entire client configuration into Keychain, sends it only to Google’s fixed token endpoint, and embeds none of it in the executable. Browser login uses a random loopback port, state validation and PKCE S256. The app never asks for the Google password. See [Google’s desktop OAuth protocol](https://developers.google.com/identity/protocols/oauth2/native-app).

Requested scopes are `https://www.googleapis.com/auth/devstorage.read_write`, `https://www.googleapis.com/auth/userinfo.email`, and `https://www.googleapis.com/auth/cloudplatformprojects.readonly`. Existing users must sign out and sign in again to grant project discovery access. The storage scope is broader than this one bucket; Google IAM supplies the actual bucket restrictions. Use an engineer account with only the access it needs. The UI shows the signed-in email. Access tokens stay in memory; refresh tokens and session capabilities use non-synchronizing, device-local Keychain entries. Sign-out clears local login and session capabilities but does not revoke Google’s grant or cancel abandoned server sessions; those expire. [OAuth expiration and token guidance](https://developers.google.com/identity/protocols/oauth2).

### Discovery permissions

Automatic project discovery requires `resourcemanager.projects.get`; listing buckets requires `storage.buckets.list` on each project. An administrator can grant only those discovery permissions through appropriate roles; do not grant Storage Admin just to populate the picker. Accounts with only create/get access on a specific bucket can use **Can’t find your bucket? → Use bucket**. See [projects.search](https://docs.cloud.google.com/resource-manager/reference/rest/v3/projects/search) and [buckets.list](https://docs.cloud.google.com/storage/docs/json_api/v1/buckets/list).

### Required bucket permissions

The smallest custom role for this implementation contains:

```text
storage.objects.create
storage.objects.get
```

Create that role in the bucket’s project and bind it to the engineer on **this bucket**. There is no need for `storage.objects.delete`, update, IAM administration or bucket administration. `get` is needed to check exact object names before upload. It also grants object-content read access; Google does not split metadata-only reads into a separate permission.

If you prefer predefined roles, bucket-level **Storage Object Creator + Storage Object Viewer** supplies create/get, with Viewer also granting list. Creator alone, suggested in the earlier conversation, is insufficient for this app’s existing-file preview. Avoid Object Admin or Object User merely to make the app work: those permit operations the uploader does not need. See [Google Storage permissions](https://cloud.google.com/storage/docs/access-control/iam-permissions) and [predefined roles](https://cloud.google.com/storage/docs/access-control/iam-roles).

## Integration verification

This build uses Foundation `URLSession` with Google’s supported JSON API, not a purported Swift GCS SDK and not parsed CLI console output. It initiates sessions with `uploadType=resumable`, supplies content length/type and `md5Hash`, saves the returned session URL, sends ranged PUT requests, and handles 308 responses and offset probes. Session URLs are bearer capabilities; they are stored only in Keychain and excluded from user-visible network errors/reports. Redirects are refused, and session endpoints must match the configured HTTPS bucket upload endpoint. See [resumable upload protocol](https://cloud.google.com/storage/docs/performing-resumable-uploads).

`ifGenerationMatch=0` allows creation only when there is no live object with that name. This provides the overwrite protection even if the object appears between preview and upload. Soft-deleted/noncurrent generations do not count as a live object. See [request preconditions](https://cloud.google.com/storage/docs/request-preconditions). Server checksum checking occurs before successful creation; the client also validates the returned size/hash. See [data validation](https://cloud.google.com/storage/docs/data-validation).

The current [`gcloud storage rsync` reference](https://cloud.google.com/sdk/gcloud/reference/storage/rsync) does list `--recursive`, `--no-clobber`, `--exclude` and `--dry-run`; the app does not rely on these flags or on earlier regex examples. No unsupported CLI flags are used because the app never launches the CLI. API and CLI documentation were checked on October 29, 2026.

## Build and develop

Requirements: Xcode with the macOS SDK and Swift 6 or newer. The package has no third-party dependencies and uses Swift 5 language mode. Deployment target is macOS 13. Open `Package.swift` in Xcode, or:

```bash
bash scripts/test.sh
bash scripts/distribute.sh
```

`distribute.sh` runs the build and verified packaging steps and puts the DMG in `dist/`. `build.sh` creates a universal Apple silicon/Intel app and ad-hoc signs it unless `SIGNING_IDENTITY` is set. Output defaults to `dist/`; `BUILD_ROOT` and `DIST_DIR` can point elsewhere. On cloud-synced folders, keeping build intermediates in a local temporary folder avoids inherited Finder metadata affecting code signing. The scripts clear extended attributes only on their generated app bundle before signing.

The scripts use SwiftPM’s `native` build engine, supported by the tested toolchain but deprecated in Swift 6.4. When adopting a future toolchain that removes it, switch to the default engine and repeat the release checks. The default engine compiled the source here, but its test signing and debug-symbol generation were affected by this managed environment.

Core networking, scanning, file integrity and Keychain code live in `Sources/BiscoCore`. SwiftUI and browser OAuth live in `Sources/BiscoArchiveUploader`. Automated protocol tests inject a fake HTTP transport; production always uses Google HTTPS endpoints. No test exposes credentials or writes to the live bucket.

## Boundaries

This is a manually started desktop uploader, not a background daemon. Quitting stops work; restart uses saved sessions after the same folder is reselected. Requester Pays billing-project configuration, hierarchical-namespace-specific permissions, customer-supplied encryption keys and custom retention controls are not implemented. The app’s table and report are kept in memory and are intended for concert archives, not multi-million-object inventories. Preview issues must be reviewed; completion of the accepted files does not mean excluded/unreadable files were archived.
