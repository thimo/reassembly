# Reassembly

iOS/iPadOS-app voor demontagefoto's. Concept, architectuurbeslissingen en open
punten staan in `SPEC.md` — lees die eerst.

## Stand van zaken

Repo bevat alleen nog de spec; het Xcode-project moet nog aangemaakt worden
(door Thimo, in Xcode — niet via CLI scaffolden).

## Conventies

- SwiftUI, geen externe dependencies tenzij besproken
- Photos is de source of truth — geen eigen datastore introduceren zonder
  expliciete afweging in SPEC.md
- Commits: kort, auteur thimo@defrog.nl, nooit pushen
