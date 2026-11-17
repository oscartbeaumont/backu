# App Store listing assets

Everything here is ready to paste into App Store Connect for the iOS app.

| File | App Store Connect field |
| --- | --- |
| `metadata/en-US/name.txt` | App name |
| `metadata/en-US/subtitle.txt` | Subtitle (30 chars max) |
| `metadata/en-US/keywords.txt` | Keywords (100 chars max, comma separated) |
| `metadata/en-US/promotional_text.txt` | Promotional text (170 chars max) |
| `metadata/en-US/description.txt` | Description |
| `metadata/en-US/release_notes.txt` | What's New |
| `metadata/en-US/support_url.txt` | Support URL |
| `metadata/en-US/marketing_url.txt` | Marketing URL |
| `metadata/en-US/privacy_url.txt` | Privacy Policy URL |
| `metadata/en-US/copyright.txt` | Copyright |
| `metadata/en-US/review_notes.txt` | App Review notes |
| `metadata/en-US/categories.txt` | Primary, then secondary category |
| `metadata/en-US/sku.txt` | SKU for the app record |

Screenshots live in `screenshots/iphone-6.9/` and `screenshots/ipad-13/`, captured
from the real app on those device classes. Regenerate them with the
`testAppStoreScreenshots` UI test (see `Tools/Screenshots/README.md`).

The privacy policy and support pages are served by the Solid landing in
`landing/` at:

- https://backu-landing.oscartbeaumont.workers.dev/privacy
- https://backu-landing.oscartbeaumont.workers.dev/support

The bundle identifier is `dev.oscartbeaumont.backu`; the app record and TestFlight
upload steps are in `AppStore/ReleaseChecklist.md`.
