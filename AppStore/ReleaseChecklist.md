# Release and TestFlight checklist

## Current status (17 Nov 2026)

- The iOS Release archive builds and signs successfully with the existing Apple
  Development identity for team **68994Z5PT3**, and the privacy manifest and
  orientations validate. The archive is at `/tmp/backu-release/Backu.xcarchive`
  during local work (not committed).
- Exporting an **App Store** IPA currently fails with `No Accounts` and no
  distribution profile for **`me.otbeaumont.backu`**: xcodebuild has no App
  Store Connect session, and the account has no Apple Distribution certificate
  or App Store profile yet. `xcodebuild` in this environment cannot create them
  without an API key.
- No App Store Connect app record exists yet for `me.otbeaumont.backu`, so an
  upload would be rejected by bundle ID anyway.
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
- [ ] Create an **explicit App ID** named `me.otbeaumont.backu` in
      Certificates, Identifiers & Profiles → Identifiers. Do **not** use a
      wildcard and do **not** enable extra capabilities. Photo-library access
      and background tasks use Info.plist keys, not App ID capabilities.
- [ ] Create the app record in App Store Connect:
  - Platform: **iOS**
  - Name: `Backu` (if taken, `Backu — Photo Backup`)
  - Primary language: English (Australia or U.S.)
  - Bundle ID: `me.otbeaumont.backu`
  - SKU: `backu-ios-1`
- [ ] If you already created an app record with a different bundle ID, create
      a **new** app record for `me.otbeaumont.backu`. App Store Connect cannot
      change the bundle ID of an existing record.
- [ ] Create an **App Store Connect API key** with the **App Manager** role
      (**Admin** if automatic signing cannot create the distribution
      certificate): Users and Access → Integrations → App Store Connect API →
      Team Keys. Download the `.p8` once; note the Key ID and Issuer ID.
- [ ] **Local network:** nothing to request on the App ID. The app includes
      `NSLocalNetworkUsageDescription`; iOS shows its standard Local Network
      prompt only when a user enters a LAN endpoint such as MinIO or Synology.

## 2. Repository secrets (owner)

Add these to GitHub → Settings → Secrets and variables → Actions:

| Secret | Value |
| --- | --- |
| `APPLE_TEAM_ID` | `68994Z5PT3` |
| `ASC_KEY_ID` | API key ID (10 characters) |
| `ASC_ISSUER_ID` | Issuer UUID |
| `ASC_PRIVATE_KEY` | full contents of `AuthKey_<id>.p8` |

Set all four at once from the downloaded key:

```sh
export APPLE_TEAM_ID=68994Z5PT3
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000
./scripts/set-testflight-secrets.sh ~/Downloads/AuthKey_XXXXXXXXXX.p8
```

The helper validates the key filename and contents, then calls `gh secret set`
for each value. It never prints the private key.

Then run **Actions → TestFlight → Run workflow** (choose the marketing version
and build number), or locally:

```sh
APPLE_TEAM_ID=68994Z5PT3 \
ASC_KEY_ID=XXXXXXXXXX \
ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8" \
BUILD_NUMBER=2 \
MARKETING_VERSION=1.0 \
./scripts/testflight.sh
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
- [ ] If testing a LAN server (MinIO, Synology, another Mac), enter its
      `http://192.168.x.x:9000` endpoint, allow the Local Network prompt, and
      confirm Test Connection and backup work.

## 4. App Store listing (owner, using the prepared files)

In App Store Connect → App Store tab, paste from `AppStore/metadata/en-US/`:

- [ ] Name, subtitle, keywords, promotional text, description, release notes.
- [ ] Support URL, marketing URL, privacy policy URL (copy from
      `AppStore/metadata/en-US/`; the landing is deployed from `landing/`).
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

## 5. China mainland distribution

The two App Store Connect notices only apply if Backu is available in China
mainland.

**Recommended: exclude China mainland.** In App Store Connect → Pricing and
Availability, remove China mainland from the selected countries. No AIGC
declaration, filing number or Security Assessment is then required.

**If you do want China mainland distribution**, complete App Store Connect →
App Compliance. Both answers can be **No** for this app:

- **AIGC services:** No. Backu does not generate or synthesise images, video,
  speech or altered faces. On-device face detection and grouping only creates
  local metadata; it does not generate or alter media.
- **Security Assessment:** No. Backu does not distribute AI-generated or
  synthetic content and has no end-to-end encrypted messaging.

The declaration itself is mandatory for any app available in China mainland,
even when the answer is No. No LLM/algorithm filing details or Security
Assessment report are needed unless those features are added later. If they
are, the filing and report must be obtained by the account owner; they cannot
be generated from this repository.

## 6. Things that cannot be automated

- Creating the app record and accepting agreements.
- API key creation and the `.p8` download.
- TestFlight external review and App Store review decisions.
- Choosing the final app name if `Backu` is already reserved.
- The first upload must be made after the app record exists; App Store Connect
  rejects a bundle ID that has no app record.

## 7. macOS

The same codebase builds a native Mac app, but TestFlight/App Store for Mac is a
separate platform in App Store Connect. Add the Mac platform to the app record
when ready, then archive with `-destination 'generic/platform=macOS'` and the
macOS export method. The iOS pipeline above intentionally uploads only iOS.
