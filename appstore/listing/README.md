# Repository App Store listings

This directory manages the product-page text and configured screenshot sets for AI Headroom
(bundle ID `com.scalexy.headroom`, Apple ID `6826866211`). The macOS copy is a draft for a
future Mac App Store release; the Mac currently ships as a notarized DMG.

Each platform has `listing.json` and one directory per App Store locale. Only locale directories
present here are managed. Other locales and screenshot display types are reported and left alone.

Each UTF-8 `.txt` file holds one value. Trailing whitespace (including the final newline) is
removed. An absent file leaves that field alone; a present empty file requests an empty value.
Apple may reject empty required fields. A new localization needs Apple's required fields supplied.

| File | API field | Limit |
| --- | --- | --- |
| `name.txt` | App info `name` | 30 characters |
| `subtitle.txt` | App info `subtitle` | 30 characters |
| `privacy_url.txt` | App info `privacyPolicyUrl` | — |
| `promotional_text.txt` | Version `promotionalText` | 170 characters |
| `description.txt` | Version `description` | 4000 characters |
| `keywords.txt` | Version `keywords` | 100 UTF-8 bytes |
| `whats_new.txt` | Version `whatsNew` | 4000 characters |
| `support_url.txt` | Version `supportUrl` | — |
| `marketing_url.txt` | Version `marketingUrl` | — |

`listing.json` requires `bundleId` and `platform` (`IOS` or `MAC_OS`), and optionally sets
`copyright` on the version. `screenshots` is an optional list of objects with `displayType` and
`folder` (relative to the repository root). An optional `locale` restricts a mapping to that
locale; without it, the mapping applies to every managed locale directory. Duplicate mappings
for a locale and display type fail validation. Screenshots upload in file-name order. Use
zero-padded names like `01-…` and `02-…` to preserve that order. A configured folder must contain
between one and ten PNGs.

```json
{
  "bundleId": "com.scalexy.headroom",
  "platform": "MAC_OS",
  "screenshots": [
    {"displayType": "APP_DESKTOP", "folder": "appstore/screenshots/2880x1800", "locale": "en-US"}
  ]
}
```

## Run from Actions

Open **Actions → App Store listing → Run workflow**, choose the platform, and run `diff` first.
It reports text changes and screenshot uploads, deletions and reordering without API writes.
Run `apply` with the same inputs to perform the changes. Run `pull` to download the **live**
listing text as an artifact, in this same platform/locale layout; it does not change the repo or
API and does not download screenshots. Its exported config has an empty screenshot list so it
cannot accidentally configure an upload. Review and copy the exported text into this directory.

Set these existing organization secrets, using an **App Manager or Admin** API key:

- `APPLE_DEVELOPER_ACCOUNT_APP_STORE_CONNECT_KEY`: raw `.p8` PEM or base64 of it
- `APPLE_DEVELOPER_ACCOUNT_APP_STORE_CONNECT_KEY_ID`
- `APPLE_DEVELOPER_ACCOUNT_APP_STORE_CONNECT_ISSUER_ID`

Locally, export those values as `ASC_KEY`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, respectively. Python's
standard library and `openssl` are the only requirements:

```sh
python3 -I Scripts/appstore_listing.py --mode diff --platform ios
python3 -I Scripts/appstore_listing.py --mode apply --platform ios --version 1.2.3 --create-version
python3 -I Scripts/appstore_listing.py --mode pull --platform ios --out /tmp/listing
python3 -I -m unittest discover -s Scripts/tests -v
```

`--listing` overrides the listing root, `--no-screenshots` skips screenshot checks and updates,
`--summary` writes a Markdown report, and `--api-base` allows an offline test server. Every local
configuration problem is checked before credentials or HTTP requests. Missing credentials exit 2,
as do invalid files. API/apply failures exit 1. A successful diff exits 0 even with differences.

The editable states are `PREPARE_FOR_SUBMISSION`, `DEVELOPER_REJECTED`, `REJECTED`,
`METADATA_REJECTED`, and `INVALID_BINARY`. Both `appVersionState` and the deprecated
`appStoreState` are read. App info also supports its newer `state` attribute. An explicit version must match the editable version, or a new version
may be created with `--create-version --version`. A new version starts with a copy of the previous
version's localizations and screenshots. Diff compares against that copy, and apply reads what
App Store Connect copied and updates only the differences. Without an editable version, only promotional
text on an existing live localization can change. App info changes require an editable app info.
Blocked changes make apply fail before any writes. The first version skips `whats_new` with a
report. Uploads are checked until processing completes (up to five minutes per new asset).

Apply is not transactional: an API failure can leave earlier changes in place. Rerun diff after
failure. Checksums and current order make successful updates safe to repeat. Replacing screenshots
in a full set removes obsolete images before reserving new ones, because Apple limits a set to 10.

## Screenshot slots to fill in

Apple's [ScreenshotDisplayType](https://developer.apple.com/documentation/appstoreconnectapi/screenshotdisplaytype)
page currently omits the possible values. Its
[list screenshot sets endpoint](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-appstoreversionlocalizations-_id_-appscreenshotsets)
confirms `APP_DESKTOP`, `APP_IPHONE_61`, `APP_IPHONE_67`, `APP_IPAD_PRO_3GEN_129`, and
`APP_WATCH_ULTRA`, among other older values. The Mac mapping uses verified `APP_DESKTOP`.
The precise mapping of the following newest dimensions to API slots could not be established
from that enum documentation. They are deliberately omitted from `ios/listing.json`, **to fill in**:

| Folder under `appstore/mobile/2-captioned/` | Slot to fill in |
| --- | --- |
| `iphone-dynamic-island-medium-1206x2622` | iPhone Dynamic Island medium |
| `iphone-duo-outer-display-1398x2034` | iPhone Duo |
| `ipad-13-inch-2752x2064` | iPad 13-inch |
| `watch-ultra-4-422x514` | Apple Watch Ultra 4 (one Watch folder only) |

Run diff with access to the listing: it prints every existing set's `screenshotDisplayType`.
Use the value for each matching device slot in `listing.json`; do not guess from the dimensions.
Before the first apply, verify the slot accepts these images. Apple's
[upload guide](https://developer.apple.com/documentation/appstoreconnectapi/uploading-assets-to-app-store-connect)
now deprecates the screenshot/set API in favor of the Asset Library and placements. This tool
implements the requested screenshot/set flow; migration to the Asset Library is future work.
A new slot may require that newer API.

## Scope

This workflow never touches app previews (videos), product page header and search-result creative
assets, categories, age rating, pricing, selecting a build, or submitting for review. It never
creates an app record. App review and publication remain manual.
