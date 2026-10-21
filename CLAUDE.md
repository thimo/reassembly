# Reassembly

iOS/iPadOS-app voor demontagefoto's. Concept, architectuurbeslissingen en open
punten staan in `SPEC.md` — lees die eerst.

## Stand van zaken

Versie 1.0 (build 6) staat sinds 2026-10-21 in de App Store
(https://apps.apple.com/app/re-assembly/id6791961916, Apple ID 6791961916).
Privacy/support-pagina: https://defrog.nl/reassembly/ (repo `~/src/defrog.nl`).
Listing-tekst en review-notities: `docs/app-store-listing.md`. Xcode Cloud is
ook geconfigureerd (bouwt bij push naar main). Nieuwe upload = eerst
`CURRENT_PROJECT_VERSION` ophogen (laatste: 6); nieuwe store-versie ook
`MARKETING_VERSION`.

CLI-builds: `xcode-select` wijst naar Command Line Tools; gebruik
`env DEVELOPER_DIR=/Applications/Xcode.app xcodebuild …`.

CLI-upload: `xcodebuild archive` (Release, generic/platform=iOS,
`-allowProvisioningUpdates`), dan `xcodebuild -exportArchive` met een
ExportOptions.plist (method `app-store-connect`, destination `upload`, teamID
SCP9WFJV88, signingStyle automatic; `docs/ExportOptions-appstore.plist`). Met
`testFlightInternalTestingOnly` true is de build alleen voor interne
TestFlight bruikbaar, nooit voor review. Let op: de exportstap moet met
`PATH=/usr/bin:/bin:/usr/sbin:/sbin` draaien, anders pakt Apple's openrsync de
Homebrew-rsync als server en faalt de export met "Copy failed".

## Conventies

- SwiftUI, geen externe dependencies tenzij besproken
- Photos is de source of truth — geen eigen datastore introduceren zonder
  expliciete afweging in SPEC.md
- Commits: kort, auteur thimo@defrog.nl, nooit pushen
