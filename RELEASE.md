# Build, sign and distribute

## Current handoff

The provided app is a universal macOS 13+ development build, with an **ad-hoc local signature**. That signature detects changes but does not establish a trusted developer identity. It is **not notarized**. No Developer ID signing identity was available in the build environment; no Apple credentials were requested or embedded.

The DMG is an installer container. The engineer drags the app into Applications. The app ZIP is an alternative distribution container. Source is provided separately. Review VALIDATION.md before sharing it as a production tool.

## Preconfigured private installer

Set `GOOGLE_OAUTH_CLIENT_FILE` to the local Google Desktop app JSON export when building:

```bash
GOOGLE_OAUTH_CLIENT_FILE='/absolute/path/to/desktop-client.json' \
DIST_DIR="$PWD/dist/1.2.1" bash scripts/distribute.sh
```

The build validates the Desktop client shape and writes a minimal `GoogleOAuthClient.json` resource before signing. It includes only `client_id` and optional `client_secret`, not project metadata, bucket names, source folders, user tokens or other exported fields. This is a desktop public-client identity and is readable by recipients; it is not an account login or a service-account key. Keep this preconfigured installer within the intended audience and out of public GitHub releases. The source repository contains only generic support and synthetic test identities.

Omitting the variable produces a generic installer with manual configuration import. Existing Keychain clients/logins take precedence over a bundled client. A fresh installation uses the bundle immediately; completing first sign-in stores its client with the user's own login in Keychain. Google audience and bucket permissions still apply.

## Trusted release

Use an Apple Developer Program account and a **Developer ID Application** certificate/private key installed in your login Keychain. Keep certificate exports, Apple API keys and local `.env` files outside source control and release artifacts. Google Desktop client configuration may be deliberately bundled for a private handoff as described below; keep the original export out of source control. Choose a bundle identifier under a domain you control before the first public release; maintain that identifier and signing identity for stable Keychain access.

1. Run the tests and live acceptance checks.
2. Build with the signing identity:

```bash
export SIGNING_IDENTITY='Developer ID Application: Your Organization (TEAMID)'
bash scripts/build.sh
```

3. Store notarization credentials in Keychain, using Apple’s interactive prompt or your organization’s approved credential workflow:

```bash
xcrun notarytool store-credentials MediaArchiveNotary
```

4. Submit and package:

```bash
export NOTARY_PROFILE=MediaArchiveNotary
bash scripts/notarize.sh
```

The script enables hardened runtime and a secure timestamp, verifies the signature, submits the app ZIP, requires an `Accepted` response, staples the app ticket, builds a DMG, signs/submits/staples the DMG, and assesses the app with Gatekeeper. `SHA256SUMS.txt` is regenerated after final packaging. It leaves the app ZIP containing the stapled app. Notarization uploads the app to Apple; run this release step only when you intend to submit it.

The executable has no bundled interpreters, unsigned helpers or downloaded code. It requires no hardened-runtime exceptions such as disabled library validation or unsigned executable memory. It is **not App Sandbox enabled**; direct-distribution apps can use the folder picker, outgoing HTTPS and a temporary loopback OAuth listener without sandbox entitlements. A Mac App Store release would require separate sandbox/bookmark and distribution work.

Apple documents the release process in [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow). The installed `notarytool` and `stapler` help was checked for the commands used here.

## Release checks

- Test on a clean Apple silicon Mac and an Intel Mac running a supported system, with a standard user account.
- Download through the actual sharing route so quarantine/Gatekeeper behavior is exercised. Confirm the app opens without requiring systemwide security changes.
- Verify Google client import, login, refresh after relaunch, permissions errors and sign-out on that machine.
- Test a real large FLAC upload, interrupt it, relaunch and resume; verify the cloud checksum. Test a same-name existing object and a concurrent creation race.
- Verify the signed/notarized artifacts after uploading to the distribution service. Share checksums separately when practical.
- Never distribute the build cache, Keychain exports, local environment configuration, unapproved OAuth configuration, live session URLs, personal reports or local recordings as part of the app/source archive.

If only a local build is available, Apple’s documented per-app override may be used for a trusted copy: [Open a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac). Do not instruct the engineer to disable Gatekeeper globally or strip quarantine across the system.
