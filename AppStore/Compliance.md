# Store compliance review

Findings from the App Store Compliance Playbook
(<https://github.com/mjmirza/app-store-compliance>) run against this repository on
18 November 2026, what was changed, what was deliberately left alone, and the
handful of checks that only the account owner can do.

Re-run the scan at any time with:

```sh
bash ~/repositories/app-store-compliance/agent-os/hooks/app-store-compliance-guard.sh "$PWD"
python3 ~/repositories/app-store-compliance/scripts/accessibility-audit.py "$PWD"
python3 ~/repositories/app-store-compliance/scripts/metadata-audit.py AppStore/metadata
```

## What was fixed

| Finding | Change |
| --- | --- |
| `APPLE-5.1.1-MISSING-PRIVACY-POLICY`. No privacy policy reachable from inside the app | Settings → About links **Privacy Policy**, **Support** and **Licence**, and the onboarding privacy card links the policy. URLs live in `ProjectLinks`. |
| `APPLE-ACCESSIBILITY-DYNAMICTYPE`. 54 hardcoded font sizes | Every hand-picked point size now goes through `View.scaledFont`, which keeps the designed size at the default text size and grows with Dynamic Type. |
| `APPLE-ACCESSIBILITY-VOICEOVER`. 7 unlabelled images and one icon-only button | Thumbnails, avatars and the brand mark are decorative inside controls that already describe them and are hidden from VoiceOver. The macOS viewer arrows are labelled Previous/Next. |
| `APPLE-ACCESSIBILITY-REDUCEMOTION`. 7 files animating without a Reduce Motion check | All content motion resolves instantly when Reduce Motion is on. The one empty `withAnimation` call is gone. |
| `APPLE-2.1-STAGING-BACKEND`. `127.0.0.1` in `Tools/Benchmark/results` | The transfer benchmark measures the bundled MockS3. The harness now requires `--endpoint`, records the mock by port instead of URL, and the unshaped profile is named `loopback` rather than `localhost`. No release build ever referenced it. |
| `BOTH-PLACEHOLDER`. `s3.example.com` in the custom-endpoint field | Replaced with `s3.your-domain.com`, which reads as an instruction rather than a sample company. |
| `APPLE-3.1.2-MISLEADING-PRICING`. The listing said "no subscription" | Reworded to "no recurring fee" and "Backu is free, with no in-app purchases", plus privacy and support links in the description. An app with no subscription should not read like one. |
| `APPLE-2.3-KEYWORD-FORMAT`. Keywords repeated name and subtitle words | Keywords tightened to 91 characters with `minio` added; the duplicate "photos" and "bucket" are gone. |
| `APPLE-2.5.4`. `UIBackgroundModes` declared `fetch` | Only `BGProcessingTask` is registered, so `processing` is the only mode used. `fetch` was removed and the review notes now describe what actually runs. |

Two copy changes were made because they also read as an account system this app
does not have: "not an OAuth login" in the add-server flow and "no end-user
OAuth flow" in `StorageProvider`. Both now say access key and sign-in in plain
words, which is clearer to a reviewer and to a reader.

## Not applicable, and why

These rules fire on wording or on a dependency that this app does not have.

- **`APPLE-5.1.1-NO-ACCOUNT-DELETION`.** Backu creates no account. There is no
  sign-up, no Backu server and no credential that identifies a person to the
  developer. Access keys for the user's own bucket are stored in the Keychain
  and can be deleted by removing the server. 5.1.1(v) has nothing to apply to.
- **`APPLE-2.3.6-SOCIAL-MEDIA-DECLARATION`.** No feed, followers, chat or live
  streaming. People and pet names stay in the user's bucket and are never shared
  with another user.
- **`APPLE-5.1.2-AI-NO-CONSENT-MODAL`.** No third-party AI service is called.
  Face and animal detection runs through Vision on the device, and face vectors
  never leave it. Nothing is sent to anyone, so there is no provider to name.
- **`BOTH-SUBSCRIPTION-HARD-CANCEL`** and the UK DMCCA subscription regime.
  There is no subscription, no in-app purchase and no cancellation path to
  provide.
- **`WEB-COOKIE-CONSENT`** and **`WEB-SESSION-STORAGE`.** The landing site sets
  no cookies and writes nothing to `sessionStorage` or `localStorage`. The
  findings came from `landing/.cloudflare`, a gitignored wrangler build cache
  that existed only on the machine the first scan ran on.
- **`APPLE-ACCESSIBILITY-HAPTICS` (15 low findings, advisory).** The rule fires
  for any file with a button. Apple does not require haptics and neither WCAG
  2.2 nor EN 301 549 does, and adding feedback to every control would be worse
  than adding none. Kept as-is deliberately.

## Owner actions before submitting

The scan cannot see the account state, and these are the blockers it names.

- [ ] Answer the 2026 age rating questionnaire in full, including **Shared
      Location** (No) and **Dating and Relationships** (No).
- [ ] Set the App Privacy answers to **Data Not Collected** and say the same in
      the privacy notes.
- [ ] Accept the current Program License Agreement and the Developer Program
      License Agreement.
- [ ] Set **DSA trader status** for EU distribution in App Store Connect. Apps
      distributed in the EU must declare trader or non-trader status.
- [ ] Exclude China mainland, or complete the AIGC and Security Assessment
      declarations. Both answers are No for this app.
- [ ] Put the reviewer through the flow in `review_notes.txt`: add a server,
      Test Connection, backup, browse, name a person, search.

## Regulatory items that touch a photo backup app

The deadline database lists items that apply to every app and items that apply
to categories this app is not in. The ones that matter here:

- **EU AI Act, Article 50 transparency (2 August 2026).** Not applicable. Backu
  does not generate or alter media, does not run a chatbot and does not send
  personal data to a model. Vision face detection groups the user's own photos
  locally.
- **EU Accessibility Act and EN 301 549.** The Dynamic Type, VoiceOver and
  Reduce Motion work above is the static half. Confirm with VoiceOver on a
  device before release, including the grid, the viewer and the add-server flow.
- **Australia, Privacy Act APP 1.7 to 1.9 (10 December 2026).** The privacy
  policy is published at <https://backu.otbeaumont.me/privacy>. Re-read it
  against the updated APP requirements before that date.
- **US state age-assurance laws (California AB 1043, Alabama HB 161 and the
  rest, 1 January 2027).** These drive the store's age assurance, which Apple
  handles. The app itself has no account, no user-generated content and no ads,
  and is rated 4+.
- **Gambling, loot boxes, AI companion chatbots, minors' social feeds.** Not
  applicable to this app.

Deadlines the guard lists for regions this app does not ship to are not repeated
here; run `scripts/deadline-checker.py` from the playbook for the live list.
