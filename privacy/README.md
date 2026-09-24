# Privacy manifests

`<Framework>.xcprivacy` is copied into that framework as
`PrivacyInfo.xcprivacy`, in the iOS and iOS simulator slices (App Store
Connect checks them; the macOS app is not distributed through the App
Store).

They declare the "required reason" APIs each library imports (`nm -u` on
the iOS slice; re-check when a dependency changes):

| Framework | Imports | Category | Reasons |
|---|---|---|---|
| Mpv | `stat`, `fstat` | FileTimestamp | C617.1, 3B52.1 |
| Mpv | `mach_absolute_time` | SystemBootTime | 35F9.1 (timers, elapsed time) |
| Avformat | `stat`, `fstat`, `lstat` | FileTimestamp | C617.1, 3B52.1 |
| Avutil | `fstat` | FileTimestamp | C617.1, 3B52.1 |
| Harfbuzz | `fstat` | FileTimestamp | C617.1, 3B52.1 |
| Mbedx509 | `stat` | FileTimestamp | C617.1, 3B52.1 |
| Xml2 | `stat` | FileTimestamp | C617.1, 3B52.1 |

C617.1: metadata (mostly the size) of files inside the app's container, the
media, subtitle, font and CA files the app hands to the player.
3B52.1: files the user picked (document picker) and the app plays.

None of the libraries collects data or tracks. mpv's `fstatfs()` (disk
space category) is compiled out on iOS by the plynic-mpv fork
(`stream_file: don't ask for the file system type on iOS`).
