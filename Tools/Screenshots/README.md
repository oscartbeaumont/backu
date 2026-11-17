# App Store screenshots

The screenshots in `AppStore/screenshots/` are captured from the real app with
the `testAppStoreScreenshots` UI test, using a dedicated simulator library of CC0 photos (landscapes and pets, plus
the simulator’s built-in sample images) and two local mock buckets shown as
“Home Backup” and “Offsite Vault”. The second destination exercises redundant
backup in the Settings screenshot.

## Regenerate

```sh
./Tools/Fixtures/download-marketing.sh
python3 Tools/MockS3/mock_s3.py --port 9001 --bucket photo-archive --region eu-west-1 \
  --data-dir /private/tmp/backu-shots --quiet &
python3 Tools/MockS3/mock_s3.py --port 9002 --bucket photo-archive-offsite --region eu-west-1 \
  --data-dir /private/tmp/backu-shots-offsite --quiet &

# iPhone 6.9" and iPad 13"
xcrun simctl erase "iPhone 17 Pro Max"        # or the current 6.9" device
xcrun simctl erase "iPad Pro 13-inch (M5)"
# boot, addmedia the marketing library, install the debug app, grant photos
```

Run the screenshot test on each device:

```sh
xcodebuild -project Backu.xcodeproj -scheme Backu \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:BackuUITests/BackuUITests/testAppStoreScreenshots \
  -resultBundlePath /tmp/backu-shots-iphone test
```

Set the status bar to Apple's canonical 9:41 before the run:

```sh
xcrun simctl status_bar "iPhone 17 Pro Max" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4
```

Then export attachments and copy them into
`AppStore/screenshots/iphone-6.9/` or `ipad-13/`:

```sh
xcrun xcresulttool export attachments --path /tmp/backu-shots-iphone.xcresult \
  --output-path /tmp/backu-shots-iphone
```

App Store Connect requires one set for 6.9" iPhone (1320×2868) and, because the
app supports iPad, one for 13" iPad (2064×2752). `sips -g pixelWidth -g
pixelHeight` verifies the sizes.
