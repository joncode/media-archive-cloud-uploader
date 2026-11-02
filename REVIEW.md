# Parallel uploads and transfer reporting — November 2, 2026

Version 1.2.0 (build 5) adds optional Preview, automatic preparation on Start, 1/2/4-file concurrency (default 2), live aggregate speed and estimated remaining time. Existing source filtering, create-only upload preconditions, Keychain namespace and checkpoint encoding are retained.

69 tests passed, zero failures. The 17 new regressions cover automatic preparation and read-only Preview, each concurrency limit, cancellation before/during uploads, global authorization failures, per-file retry isolation, scan-issue blocking, old preferences/checkpoints, correct resumed-byte accounting, shared refresh/sign-out/cancellation behavior, actual overlapping StorageClient transfers, and real URLSession upload-progress callbacks against a temporary localhost server. The localhost server also returns a 308 with a redirect target; the client correctly refuses the redirect. All Google responses are simulated and all audio is synthetic. No live bucket was accessed during this development pass.

Review findings addressed: concurrent token refreshes now share one request; late results after cancellation/sign-out cannot restore credentials; hashing runs off the storage actor; initial saved offsets are excluded from new-byte throughput; late body-progress callbacks are ignored after their request ends; fatal authorization failures cancel/drain active workers before another run can start. Preparation failures remain reportable and do not silently start a partial upload.

The universal arm64/x86_64 build is packaged separately in `dist/1.2.0` so the running 1.1.1 app and previous installer remain untouched. This release remains ad-hoc signed and unnotarized. The user reported the prior version working; actual performance with 1/2/4 workers, live cloud interruption/recovery and ETA behavior on their source drive and connection still require user acceptance testing. No speedup is claimed from the simulated concurrency tests. See TESTING.md.

---

# Public rename — November 1, 2026

Version 1.1.1 (build 4) is named **Media Archive Cloud Uploader**. App windows, Google login return text, report headers, installer names, source modules and build/release scripts use the new name. The existing bundle identifier, Keychain service, Application Support folder and advanced environment variable names are retained for compatibility with existing installations.

52 automated tests passed after the rename, with zero failures. No new Google login or cloud uploads were performed for this branding release. The prior live-account, permissions, transfer and notarization acceptance checks still apply. The upload filter remains FLAC/WAV/MP3 only.

---

# GUI setup review — October 31, 2026

Version 1.1.0 (build 3) replaces required environment-file setup with sign-in, bucket selection and Finder file/folder selection. `.env` is now an optional advanced import; existing private values are not changed or bundled.

52 XCTest tests passed with zero failures. Ten new tests cover paginated project/bucket discovery, partial permission failures, token refresh on 401, transient retries, cancellation, repeated-page protection, explicit-file filtering, private settings persistence, account-bound destination restoration, guided first sign-in and persistence failure. The first restricted test invocation could not open localhost sockets; rerunning with local network access passed the real callback tests. All cloud listing responses in tests were simulated; no real Google account or bucket was accessed.

The app requests Google's read-only project discovery scope in addition to its existing storage/email scopes. Automatic discovery needs Resource Manager enabled and project viewing/bucket listing permissions; a manual project/bucket fallback supports more restricted accounts. The picker never automatically chooses the first bucket. Changing destinations invalidates the preview; changing accounts clears the destination. Credentials remain in Keychain; settings use an owner-only Application Support JSON file.

The release was compiled for Apple silicon and Intel. Live consent, actual project/bucket discovery under the user's IAM permissions, actual upload/resume and interactive testing on the engineer's Mac remain acceptance checks. This remains an ad-hoc signed, unnotarized test release.

---

# Review and test readiness — October 30, 2026

Version 1.0.1 (build 2) is suitable for a small user trial, subject to Google OAuth/IAM setup. It is not yet validated for unattended production archives. No real account login, cloud upload, deletion or overwrite was performed during this review.

## Findings fixed

- **Object name encoding:** Literal `+` characters were left in the initiation URL’s query. They are now encoded as `%2B`, preserving filenames through form-style query decoding. The regression test checks the wire representation rather than only URLComponents round-tripping.
- **Expired authentication:** Refresh failures now stop the batch and ask for sign-in instead of repeating for each file. Temporary token-service failures still use bounded retry. Replacement refresh tokens are saved, and malformed token responses fail safely.
- **Sign-out and cancellation:** Sign-out discards the in-memory token even when Keychain cleanup fails. A cleanup error remains visible; the user must unlock Keychain and retry sign-out to remove persisted data. Cancelling the login task now closes its callback listener and resumes the waiting task. Startup cancellation preserves the actual error type.
- **Configuration inputs:** Imports are bounded to 64 KiB and reject nonregular files and final-component symlinks. They cannot block on a named pipe. Imported environment files are stored beneath an owner-only directory with owner-only file permissions. Real configuration remains Git-ignored and is not bundled.
- **Resume handling:** Corrupt or expired saved state is discarded and a new session starts with the same create-only precondition. An acknowledgement beyond the bytes sent is rejected.
- **File scan/reporting:** Missing or invalid source folders report an error. A report can be exported when every file was excluded or only scan issues were found.
- **Resource lifetime:** The HTTP session uses a separate redirect delegate so it does not retain its client indefinitely after configuration changes. Cross-host redirects remain refused.
- **Distribution:** `scripts/distribute.sh` builds the universal app and creates the DMG/ZIP in the repo’s `dist` directory. Packaging verifies a clean staged app, the disk image and the ZIP-extracted signature before replacing the last installer.

## Evidence

42 XCTest tests passed with zero failures on the build Mac using Xcode 27.2. The tests include file filtering, FLAC/MP3/RF64/BW64 containers, source-change detection, create-only upload requests, existing-object races, interrupted transfer recovery, actual task cancellation, bucket-scoped checkpoints, literal configuration parsing, Keychain-failure behavior, token refresh/cache behavior and a real localhost OAuth callback listener with synthetic codes.

The SwiftUI application and both arm64/x86_64 release targets compile. Tests use fake Google responses, synthetic audio and an isolated credential store. They do not prove live service interoperability or substitute for a real account test. No third-party runtime dependencies or embedded user credentials are present.

## Remaining checks

- Real Google Desktop OAuth client import, consent, token refresh and bucket permissions.
- A small real upload, cloud checksum/generation inspection and live cancel/resume.
- An Intel Mac and the oldest supported macOS version; cross-compilation alone is not runtime coverage.
- Developer ID signing, Apple notarization and installation through the intended sharing channel.
- Performance on a representative concert archive and slow/interrupted venue connectivity.

The review focused on upload correctness, credential boundaries, file handling and release reproducibility. It is not an independent security audit or a guarantee that no defects remain. TESTING.md gives the next acceptance steps.
