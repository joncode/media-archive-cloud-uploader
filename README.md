# Bisco Archive Uploader

A native SwiftUI macOS app for uploading FOH recordings to a Google Cloud Storage bucket configured locally. The selected folder’s **contents go to the bucket root by default**, as explicitly requested. A visible switch can include the selected folder’s name.

Start with [TESTING.md](TESTING.md) for the first controlled trial and [REVIEW.md](REVIEW.md) for current findings and limits.

Read [QUICK-START.md](QUICK-START.md) for the engineer’s workflow and [RELEASE.md](RELEASE.md) for packaging. [VALIDATION.md](VALIDATION.md) records what was actually tested and what still needs a real account.

## What is implemented

- Native folder picker, Google browser login, account display and local sign-out.
- Recursive audio-only scan: case-insensitive `.flac`, `.wav`, `.mp3` plus AudioToolbox container/type and nonzero audio-data validation. No symlinks, hidden paths, AppleDouble or REAPER uploads. Excluded paths and unreadable paths appear in the exported report.
- Explicit preview before uploading. Signed-out preview is local; signed-in preview checks cloud metadata with GET requests. It creates no upload sessions.
- Existing objects skipped by name. Every new upload is protected by `ifGenerationMatch=0`, including retries and replacements of expired sessions. A 412 response is a safe skip. A 403 is an error, never “not found.”
- Sequential uploads with bounded 8 MiB chunks, acknowledged-byte progress, per-file status, errors, exported reports, exponential backoff with jitter, cancellation and retry.
- Keychain-persisted resumable session URLs. On restart, the engineer reselects the folder and previews. The app queries the saved server offset instead of guessing how many bytes arrived. Sessions older than six days are restarted, ahead of Google’s one-week expiry.
- SHA-256 binds a saved session to the exact source content; MD5 is supplied as object metadata for server-side transfer validation and checked in the completion response. File identity, size and modification time are also checked while reading.
- No shell execution, runtime package downloads, bundled Python, CLI dependency, service account key, embedded Google client, user credential or analytics.

The app does not change storage class, bucket settings, object ACLs or retention. It inherits the bucket defaults. It does not delete or overwrite objects. Existing same-name objects are not content-verified. A generic audio container check is deliberately conservative: some unusual WAV variants may be excluded and need separate review. Uploads are one file at a time; performance tuning and parallel transfers are future work.

## Local environment configuration

No production bucket name or source-folder path is compiled into the app or checked into Git. Uploads remain disabled until a destination is configured.

- `BISCO_GCS_BUCKET`: required bucket name, without `gs://` or a path.
- `BISCO_SOURCE_FOLDER`: optional absolute default source path. The folder picker can override it.
- `BISCO_ENV_FILE`: optional absolute path to a local environment file, for development or managed launches.

Copy `.env.example` to `.env` and fill in your real values locally. `.env` and other `.env.*` files are ignored; only the empty `.env.example` is tracked. Never add a real configuration to Git, a source ZIP or a release bundle.

For Finder launches, use **Setup → Import environment configuration (.env)…**. This copies the file to the app’s per-user Application Support directory with owner-only file permissions. The engineer can do this without Terminal. For development, `bash scripts/run.sh` points the app at the repository’s ignored `.env`. Finder does not inherit shell exports; use the import option or launch the executable with its environment explicitly set.

Process environment variables override file values. `BISCO_ENV_FILE`, when set, selects the file instead of the imported per-user copy. Missing or invalid configuration blocks uploads. Values are literal, optionally quoted; the parser does not execute shell commands or expand variables. Choose **Reload environment configuration** after an external change. A changed destination clears the preview; resume sessions are scoped to their bucket.

## One-time Google setup — archive administrator

1. In your Google Cloud project, enable the Cloud Storage API if needed. Configure Google Auth Platform branding, audience and data access.
2. Create an OAuth client of type **Desktop app**, then download its JSON. This app accepts the `installed` JSON shape, not a Web client or service account key. Supply the file separately to the engineer, who imports it through Setup. Do not commit it into source or place it in the release bundle.
3. Permit the engineer’s Google account to authorize the app. While an external consent screen is in Testing, add that account as a test user. Testing-mode refresh tokens can expire after seven days; move to the appropriate production/internal configuration and complete any Google verification required for your audience and scopes.
4. Grant bucket access as described below. Run the live acceptance checks in VALIDATION.md before treating the build as production-ready.

Google desktop clients are public clients: their downloaded `client_secret`, when present, is not a durable confidential secret. This implementation nonetheless imports the entire client configuration into Keychain, sends it only to Google’s fixed token endpoint, and embeds none of it in the executable. Browser login uses a random loopback port, state validation and PKCE S256. The app never asks for the Google password. See [Google’s desktop OAuth protocol](https://developers.google.com/identity/protocols/oauth2/native-app).

Requested scopes are `https://www.googleapis.com/auth/devstorage.read_write` and `https://www.googleapis.com/auth/userinfo.email`. The storage scope is broader than this one bucket; Google IAM supplies the actual bucket restrictions. Use an engineer account with only the access it needs. The UI shows the signed-in email. Access tokens stay in memory; refresh tokens and session capabilities use non-synchronizing, device-local Keychain entries. Sign-out clears local login and session capabilities but does not revoke Google’s grant or cancel abandoned server sessions; those expire. [OAuth expiration and token guidance](https://developers.google.com/identity/protocols/oauth2).

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
