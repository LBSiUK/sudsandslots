# Suds & Slots

Laundry-slot booking app for the household, iPadOS 15 (SwiftUI), built for the
jailbroken iPad Mini 4 in landscape.

- `./build.sh` → fake-signed Sileo `.deb`s (rootless + rootful) in `build/`
- `xcodegen` → `SudsAndSlots.xcodeproj` for simulator runs (no iOS 15 simulator on
  this macOS, so check on iOS 26; the swiftc build in build.sh targets iOS 15.0 and
  fails on any newer API)
- Debug launch args: `-demo` seeds sample bookings, `-mini4` pins the UI to
  1024x768pt, `-landscape` rotates (iOS 16+ only)
- App icon: `swiftc -parse-as-library scripts/make_icon.swift Sources/SudsAndSlots/Theme.swift -o /tmp/mkicon && /tmp/mkicon`

Bookings are stored on-device (UserDefaults JSON). Tap a booking to cancel it.
