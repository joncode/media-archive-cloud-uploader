# Validation record

Current review: [REVIEW.md](REVIEW.md), October 30, 2026. The expanded suite passes 42 tests on Xcode 27.2; see TESTING.md for the live checks still required.

## Initial validation — October 29, 2026

## Verified here

- Native SwiftUI source compiled with Xcode 27.1 / Swift 6.4, targeting macOS 13.
- Release executable built for **arm64 and x86_64** and combined into a universal app. Only Apple system frameworks/libraries are linked; no Google CLI or third-party runtime is required.
- **26 automated XCTest tests passed, zero failures** on the build Mac. Test execution used a local temporary build directory and SwiftPM’s native build engine to avoid cloud-folder metadata affecting test-bundle signing.
- Local protocol simulations covered existing-object skip, GET-only preview checks, 403 permission errors, atomic create preconditions, 412 creation races, checksums, interrupted chunks, server offset queries, saved-session resume across client instances, cancellation handling, expired sessions, bounded retries and malformed server ranges.
- Scanner tests covered nested relative names, the optional folder prefix, hidden/AppleDouble paths, symlinks, wrong extensions, source changes and real FLAC/MP3/WAV containers. RF64 and BW64 containers were included for long WAV recordings. The path tests exposed and verified a fix for macOS `/var` versus `/private/var` normalization.
- OAuth tests exercised a real temporary **127.0.0.1** listener with synthetic authorization codes: valid callback, invalid/duplicate state, declined consent and cancellation. PKCE S256 was checked against the RFC test vector; form encoding and secure random verifier length were also checked.
- The app was launched and its initial SwiftUI window visually inspected. The screenshot in the handoff is the actual application, not a mockup. UI automation was unavailable because the computer-use Accessibility permission had not been enabled; interactive folder-picker and export clicks were not automated.
- Build/package shell syntax checked. Ad-hoc signatures verified on the clean packaged app. Installer image integrity and the ZIP-extracted app signature were checked after packaging.

Tests are in `Tests/BiscoCoreTests`. Fixture audio is synthetic: tiny FLAC/MP3 silence streams and short generated WAV tones in RF64/BW64 containers. Both silence formats were successfully decoded by macOS `afconvert`. Fixtures contain no concert recordings or third-party audio.

- Environment configuration tests covered missing configuration, process/file precedence, quoted paths, literal parsing, malformed bucket/path rejection, explicit file loading and bucket-isolated resume sessions.

## Not verified here

- **No real Google login, token refresh or GCS upload was performed.** No Desktop OAuth client configuration was supplied. Existing gcloud credentials were not read or reused. No objects were created, changed or deleted in the live archive bucket.
- Google’s actual consent-screen configuration, the engineer’s bucket IAM permissions, real service-side checksum rejection and concurrent upload races remain live acceptance checks. Network tests simulate GCS responses; they do not substitute for a live smoke test.
- Intel was cross-compiled, not run on physical Intel hardware. macOS 13 compatibility is the deployment target, not a claim that every supported OS has been tested.
- No Developer ID certificate was available. The build is **ad-hoc signed, unnotarized**, and no Apple notarization submission was made. `notarize.sh` was reviewed and syntax-checked but cannot be end-to-end verified without a signing identity and Apple credentials.

## First live acceptance run

Use a few small test recordings whose object names the administrator has approved for the production bucket, or set `BISCO_GCS_BUCKET` in your local configuration to a disposable test bucket. No source changes are needed to change the destination.

1. Configure the Desktop OAuth client and least-privilege bucket access from README.md. Import the JSON, sign in as the engineer and confirm the displayed email.
2. Select a folder containing FLAC/WAV/MP3, AppleDouble, REAPER files and a symlink. Preview. Verify the object paths and that the rejected files are absent. Verify no objects were created by preview.
3. Start upload. Inspect the resulting object size/hash and bucket-default storage class. Rerun and confirm same-name objects are skipped without generation changes.
4. Use a larger file, disconnect briefly during transfer, reconnect and confirm automatic recovery. Cancel, quit, relaunch, select the same folder and resume. Confirm the source is unchanged and progress resumes from Google’s saved offset when the session remains valid.
5. Modify a source after preview and confirm it is refused. Confirm an account without get/create access reports an error instead of pretending files are missing.
6. Test sign-out, relaunch and sign-in; check consent denial and token expiry. Sign-out must remove locally saved login/resume entries. Verify the engineer can complete folder selection and report export without Terminal.
7. Before broad distribution, sign/notarize and run the clean-Mac checks in RELEASE.md.

No automated acceptance step deletes test objects. The administrator should choose destinations deliberately, especially for an ARCHIVE bucket with retention/cost implications.
