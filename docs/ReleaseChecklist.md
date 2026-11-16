# Release and TestFlight checklist

## Current status (17 Nov 2026)

- The iOS Release archive builds and signs successfully with the existing Apple
  Development identity for team **68994Z5PT3**, and the privacy manifest and
  orientations validate. The archive is at `/tmp/backu-release/Backu.xcarchive`
  during local work (not committed).
- Exporting an **App Store** IPA currently fails with `No Accounts` and
  `No profiles for 'dev.oscartbeaumont.backu' were found`: xcodebuild has no
  App Store Connect session, and the account has no Apple Distribution
  certificate or App Store profile yet. `xcodebuild` in this environment cannot
  create them without an API key.
- No App Store Connect app record exists yet, so an upload would be rejected by
  bundle ID anyway.
- The listing assets, privacy manifest, screenshots, privacy/support pages and
  the manual TestFlight workflow are ready.

**To finish, the account owner needs to do two things:** create the app record,
and provide an App Store Connect API key (App Manager) so the archive can be
signed for distribution and uploaded. The key is also what lets the workflow
create the distribution certificate and profile automatically. No `.p12` or
`.mobileprovision` secrets are needed.

Everything that can be prepared in the repository is already here: the bundle
identifier, icon, privacy manifest, metadata, screenshots, pages, archive script
and the manual TestFlight workflow. The items marked **owner** need the Apple
account and cannot be done by an automated agent.

## 1. Apple account prerequisites (owner)

- [ ] Apple Developer Program membership for team **68994Z5PT3** (an Apple
      Development certificate already exists for this Mac).
- [ ] Sign in to App Store Connect and accept the latest Program License
      Agreement and the Free Apps agreement.
- [ ] Complete the **Paid Apps** tax and banking sections if the app will ever be
      paid. Free apps still need the agreements accepted.
- [ ] Create the app record in App Store Connect:
  - Platform: **iOS**
  - Name: `Backu` (if taken, `Backu — Photo Backup`)
  - Primary language: English (Australia or U.S.)
  - Bundle ID: `dev.oscartbeaumont.backu`
  - SKU: `backu-ios-1`
- [ ] The bundle ID can be registered automatically by Xcode's automatic
      signing; otherwise register it in Certificates, Identifiers & Profiles.
- [ ] Create an **App Store Connect API key** with the **App Manager** role:
      Users and Access → Integrations → App Store Connect API → Team Keys.
      Download the `.p8` once; note the Key ID and Issuer ID.

## 2. Repository secrets (owner)

Add these to GitHub → Settings → Secrets and variables → Actions:

| Secret | Value |
| --- | --- |
| `APPLE_TEAM_ID` | `68994Z5PT3` |
| `ASC_KEY_ID` | API key ID (10 characters) |
| `ASC_ISSUER_ID` | Issuer UUID |
| `ASC_PRIVATE_KEY` | full contents of `AuthKey_<id>.p8` |

Then run **Actions → TestFlight → Run workflow**, or locally:

```sh
APPLE_TEAM_ID=68994Z5PT3 \
ASC_KEY_ID=XXXXXXXXXX \
ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8" \
BUILD_NUMBER=2 ./scripts/testflight.sh
```

`scripts/testflight.sh` archives with automatic signing, exports an App Store
IPA and uploads it with `altool`. `SKIP_UPLOAD=1` stops after the IPA.

## 3. First build on TestFlight (owner)

- [ ] Wait for App Store Connect processing (usually 5–20 minutes).
- [ ] Answer the export-compliance question if asked: the app uses only
      exempt HTTPS and `ITSAppUsesNonExemptEncryption` is already `false`.
- [ ] Add yourself to **Internal Testing**. Internal testers can install
      immediately.
- [ ] For external testing, create a group and submit the build to **Beta App
      Review**; TestFlight metadata is already in `AppStore/metadata`.
- [ ] Install from TestFlight on a device with photos and an S3 bucket, and run
      through: add server → Test Connection → automatic backup → browse →
      name a person/pet → search → open a remote photo from another device.

## 4. App Store listing (owner, using the prepared files)

In App Store Connect → App Store tab, paste from `AppStore/metadata/en-US/`:

- [ ] Name, subtitle, keywords, promotional text, description, release notes.
- [ ] Support URL, marketing URL, privacy policy URL (the three GitHub Pages
      pages in `Docs/`).
- [ ] Screenshots: `AppStore/screenshots/iphone-6.9/` and
      `AppStore/screenshots/ipad-13/` (upload in filename order).
- [ ] Category: Photo & Video (primary), Productivity (secondary).
- [ ] Age rating: 4+ (no user-generated content, no web browsing, no ads).
- [ ] Price: Free. Availability: all countries.
- [ ] App Privacy:
  - Data Not Collected.
  - Explain in the privacy notes that photos go only to the user's own bucket,
    face vectors stay on-device, and there are no analytics or tracking SDKs.
- [ ] Content rights: the app displays only the user's own photos.
- [ ] Review notes: `AppStore/metadata/en-US/review_notes.txt`.
- [ ] Build: select the uploaded TestFlight build.
- [ ] Submit for review.

## 5. Things that cannot be automated

- Creating the app record and accepting agreements.
- API key creation and the `.p8` download.
- TestFlight external review and App Store review decisions.
- Choosing the final app name if `Backu` is already reserved.
- The first upload must be made after the app record exists; App Store Connect
  rejects a bundle ID that has no app record.

## 6. macOS

The same codebase builds a native Mac app, but TestFlight/App Store for Mac is a
separate platform in App Store Connect. Add the Mac platform to the app record
when ready, then archive with `-destination 'generic/platform=macOS'` and the
macOS export method. The iOS pipeline above intentionally uploads only iOS.
