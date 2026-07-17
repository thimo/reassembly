# Reassembly

iOS/iPadOS-app voor demontagefoto's. Concept, architectuurbeslissingen en open
punten staan in `SPEC.md` — lees die eerst.

## Stand van zaken

App is gebouwd en draait via TestFlight (internal testing) op Thimo's iPhone.
App Store Connect-record "Re-assembly" bestaat (Apple ID 6791961916); uploaden
gaat lokaal via Product → Archive → TestFlight Internal Only. Xcode Cloud is
ook geconfigureerd (bouwt bij push naar main). Nieuwe upload = eerst
`CURRENT_PROJECT_VERSION` ophogen.

CLI-builds: `xcode-select` wijst naar Command Line Tools; gebruik
`env DEVELOPER_DIR=/Applications/Xcode.app xcodebuild …`.

## Conventies

- SwiftUI, geen externe dependencies tenzij besproken
- Photos is de source of truth — geen eigen datastore introduceren zonder
  expliciete afweging in SPEC.md
- Commits: kort, auteur thimo@defrog.nl, nooit pushen
