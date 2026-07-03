# Reassembly — spec

iOS/iPadOS-app voor demontagefoto's: fotografeer tijdens het uit elkaar halen, zodat je bij het in elkaar zetten weet hoe het moet. Geboren uit een accu-teardown. Ook voor documenteren van pure bouwprojecten — de naam dekt dan niet de lading maar blijft staan als (Haynes-)grap; app is voor eigen gebruik, dus hernoemen kan altijd nog.

- Engelse tagline: *"Re-assembly is the reverse of disassembly."* (Haynes-cliché)
- Nederlandse tagline: *"Gelukkig hebben we de foto's nog."*

## Kernprincipe: Photos ís de database

De app slaat zelf (vrijwel) niets op. Alle foto's, structuur en sync leven in de
iCloud Photo Library. Elke byte eigen opslag is CloudKit-sync-complexiteit die
we anders gratis krijgen. Eigen data (SwiftData + CloudKit) pas toevoegen als
het echt niet anders kan.

## Structuur

Spiegel van de Photos-hiërarchie, onder één root-folder "Reassembly" in Photos:

- **Folder** = `PHCollectionList` — mag nesten (klant → project → …), voor commercieel gebruik
- **Album** = `PHAssetCollection` — bevat de foto's

App-structuur en Photos-structuur zijn 1-op-1; beheer (hernoemen, verplaatsen,
weggooien) werkt dus ook vanuit de Photos-app.

## Schermen

1. **Projectenlijst** — folders/albums, gesorteerd op laatste activiteit
   (= datum nieuwste asset per album; folders recursief op nieuwste asset
   eronder). Lege items zakken naar onderen. Een nieuw project (album/folder)
   opent meteen na aanmaken, dus lege items zijn zeldzaam.
   - **Aanmaakdatum-sortering losgelaten.** PhotoKit geeft geen album-
     aanmaakdatum; de benadering (oudste asset) is onbetrouwbaar bij lege of
     later-gevulde albums. Zelf onthouden zou lokaal simpel zijn maar synct
     niet (per-device divergentie); syncen kan via `NSUbiquitousKeyValueStore`
     op cloud-identifier, maar een net gemaakt album heeft nog geen cloud-id
     (die ontstaat pas na iCloud-upload) — te veel bewegende delen voor te
     weinig winst. Auto-open maakt de hele kwestie moot; besluit: niet doen.
2. **Album** — fotogrid, nieuwste bovenaan, prominente camera-knop.
3. **Camera** — AVFoundation; het geselecteerde album blijft actief zodat een
   volgende foto één tik is.

### Quick actions

Doel: camera in het actieve project zonder door de app te navigeren.

- **Icoon long-press** (`UIApplicationShortcutItem`): "Foto in <actief project>"
  + dynamisch de 2-3 recentste projecten
- **App Intent + ControlWidget** "Maak foto in actief project" — één
  implementatie, meteen bruikbaar op meerdere plekken: Control Center,
  de vervangbare lock-screen-knoppen (waar standaard de Camera-app zit —
  sinds iOS 18 mag daar een eigen control), Action Button en Shortcuts/Siri
- **LockedCameraCapture** (iOS 18): fotograferen vanaf het lock screen zónder
  eerst te ontgrendelen — nodig om die lock-screen-knop echt goed te maken;
  opslaan naar het album kan pas na unlock, dus buffer + afhandelen bij
  eerstvolgende ontgrendeling

Projecten hebben een **delete all**: album + alle foto's in één actie.
Eén `performChanges`-blok met `PHAssetChangeRequest.deleteAssets` +
`PHAssetCollectionChangeRequest.deleteAssetCollections`; iOS toont zelf één
systeem-bevestiging voor de foto's (niet te omzeilen, hoeft dus geen eigen
confirm). Foto's belanden 30 dagen in "Recent verwijderd" — herstelbaar.
Let op: assets verdwijnen library-breed, ook als ze in een ander album zitten.

## Techniek

- SwiftUI, één codebase iPhone + iPad; minimum iOS 18 (ControlWidget op lock
  screen + LockedCameraCapture vereisen dat toch al)
- Eigen state: alleen "actief project" (UserDefaults) — verder niets
- PhotoKit: `PHCollectionListChangeRequest` / `PHAssetCollectionChangeRequest` /
  `PHAssetCreationRequest`
- AVFoundation-camera + CoreLocation: geotag zelf op de `PHAssetCreationRequest`
  zetten (in-app camera's geotaggen níet vanzelf); datum gaat vanzelf
- Permissions: volledige library-toegang (`.readWrite`) — nodig voor albums
  aanmaken/uitlezen; limited-access-modus netjes afvangen
- `PHPhotoLibraryChangeObserver`: gebruiker kan structuur in Photos zelf wijzigen
- Bij eventuele eigen verwijzingen naar assets/albums: cloud identifiers
  (iOS 15+), nooit `localIdentifier` (niet stabiel tussen devices)

## App Store

- Naam "Reassembly" vrij in US store (iTunes Search API, gecheckt 2026-07-03);
  definitief pas bij reservering in App Store Connect
- PC-game *Reassembly* (Steam) bestaat; andere categorie, laag risico

## Definitief: opslag in Photos, app wordt geen product

Assets in de library verschijnen altijd in Recents — "alleen in albums" bestaat
niet in PhotoKit (`isHidden` verbergt ook uit albums; geen route). Dat is
acceptabel, want de app is en blijft voor eigen gebruik: Thimo wil de
commerciële activiteit (marketing, support) die een product vereist niet —
zelfde besluit als bij zijn andere macOS-projecten. Solo-commercieel sleutelen
(klant-folders) kan gewoon binnen dit model; desnoods aparte Apple ID op een
werkplaats-device. Eigen opslag + CloudKit-sync is daarmee definitief van tafel.

## Open punten

- Spelling op homescreen: "Reassembly" of "Re-Assembly"
- Naam reserveren in App Store Connect
- Xcode-project aanmaken (nog niet gedaan)
- Icon
