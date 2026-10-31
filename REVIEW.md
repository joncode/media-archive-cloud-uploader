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
