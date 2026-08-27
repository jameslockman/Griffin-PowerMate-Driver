# Creating a Signed, Notarized Installer for PowerMate Agent

To distribute PowerMate Agent so anyone can use it (without “unidentified developer” warnings), you need to **sign** the app with an Apple Developer ID and **notarize** it. Users will still need to grant **Input Monitoring** (or Accessibility) once—macOS requires that for any app that injects keyboard/mouse events; you cannot bypass or pre-grant it.

## 1. Prerequisites

- **Apple Developer account** (paid): [developer.apple.com](https://developer.apple.com)
- **Xcode** (or Xcode Command Line Tools) with a recent macOS SDK
- **Developer ID Application** certificate: in [App Store Connect → Certificates, IDs & Profiles](https://developer.apple.com/account/resources/certificates/list), create a **Developer ID Application** certificate and install it in Keychain.

## 2. Build the app bundle

**One-shot (build + sign + DMG + notarize + staple):** Use a secrets file and run the packaging script from the repo root:

```bash
cp secrets.json.example secrets.json
# Edit secrets.json: developer_id_cert, apple_id, team_id, app_specific_password
chmod +x scripts/build-and-package.sh
./scripts/build-and-package.sh
```

The script reads `developer_id_cert`, `apple_id`, `team_id`, and `app_specific_password` from `secrets.json`. Keep `secrets.json` out of version control (it is listed in `.gitignore`).

**Manual steps** (same workflow as the script):
From the repo root:

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
```

This produces **`.build/release/PowerMate Agent.app`** (release binary + Info.plist). The app shows both menu-bar and Dock icons by default; users can hide the Dock icon from its menu.

## 3. Sign the app

Replace `"Developer ID Application: Your Name (TEAM_ID)"` with your actual certificate name (find it in Keychain Access or `security find-identity -v -p codesigning`).

```bash
codesign --force --deep --sign "Developer ID Application: your-id-here" \
  --options runtime \
  ".build/release/PowerMate Agent.app"
```

The **`--options runtime`** (hardened runtime) flag is required for notarization.

Verify:

```bash
codesign -dv --verbose=2 ".build/release/PowerMate Agent.app"
```

## 4. Create a disk image (for distribution)

If you get **"Operation not permitted"** when creating the DMG:

1. **Grant Full Disk Access** to your terminal app (Terminal, iTerm, etc.): **System Settings → Privacy & Security → Full Disk Access** → add your terminal app and enable it. Quit and reopen the terminal, then try again.
2. Unmount any existing volume from a previous run:  
   `hdiutil detach "/Volumes/PowerMate Agent" 2>/dev/null; hdiutil detach "/Volumes/PowerMateAgent-1.0.0" 2>/dev/null; true`

**Option A — script:** The DMG contains the app, an Applications alias, and (if present) **scripts/dmg.DS_Store** so the window opens in icon view with larger icons. To generate that file once, run `./scripts/make-dmg-dsstore.sh` (opens a temp folder in Finder and captures its .DS_Store), then commit **scripts/dmg.DS_Store**. If the file is missing, the DMG still builds with default view.

```bash
chmod +x scripts/create-dmg.sh
./scripts/create-dmg.sh
```

**Option B — manual:**

```bash
cd .build/release
hdiutil detach "/Volumes/PowerMate Agent" 2>/dev/null || true
hdiutil detach "/Volumes/PowerMateAgent-1.0.0" 2>/dev/null || true
hdiutil create -volname "PowerMateAgent-1.0.0" -srcfolder "PowerMate Agent.app" -ov -format UDZO "PowerMateAgent-1.0.0.dmg"
cd ../..
```

## 5. Notarize the app (or DMG)

Submit the **.app** (or the **.dmg**) to Apple for notarization. You need an **App-specific password** for your Apple ID (create at [appleid.apple.com](https://appleid.apple.com)).

```bash
xcrun notarytool submit ".build/release/PowerMate Agent.app" \
  --apple-id "your-apple-id-here" \
  --team-id "your-team-id-here" \
  --password "your-password-here" \
  --wait
```

Or notarize the DMG:

```bash
xcrun notarytool submit ".build/release/PowerMateAgent-1.0.0.dmg" --apple-id "your-apple-id-here" --team-id "your-team-id-here" --password "your-password-here" --wait
```

Then **staple** the notarization ticket to the app (or DMG):

```bash
xcrun stapler staple ".build/release/PowerMate Agent.app"
# If you distributed the DMG:
xcrun stapler staple ".build/release/PowerMateAgent-1.0.0.dmg"
```

## 6. What to ship

- **Option A:** Zip or distribute **PowerMate Agent.app** (after signing and stapling). User copies it to **Applications** and runs it.
- **Option B:** Distribute the **.dmg**. User opens the DMG and drags the app to Applications.

There is **no separate installer**—the DMG is the distribution. The user drags **PowerMate Agent** to Applications, then double-clicks the app to run it. The app has no window: a **menu bar icon** (filled circle) appears so they can see it's running and choose **Quit PowerMate Agent** to exit. The first time they use the dial, macOS will prompt for **Input Monitoring** (or Accessibility); they must enable the app in System Settings.

**App icon:** The app shows a system default icon unless you add one.

- **Option A — from a single PNG (e.g. exported from Xcode or designed at 1024×1024):**  
  `iconutil` does **not** accept Xcode’s **Asset Catalog** format (`Assets.xcassets/AppIcon.appiconset`); that causes “Invalid Iconset”. Use the helper script instead, which builds a valid `.iconset` and runs `iconutil`:
  ```bash
  chmod +x scripts/make-app-icon.sh
  ./scripts/make-app-icon.sh /path/to/icon.png
  ```
  Use a 1024×1024 or 512×512 PNG. If your icon lives in an Xcode asset catalog, pick the **largest** PNG in that folder (e.g. `Icon-App-1024x1024@1x.png` or similar) as the path. The script creates **scripts/AppIcon.icns**. Then run the app build script again so the icon is copied into the app bundle.

- **Option B — manual .iconset:**  
  Create a folder named `AppIcon.iconset` (standalone, not inside `.xcassets`) containing exactly these PNG filenames: `icon_16x16.png`, `icon_32x32.png`, `icon_128x128.png`, `icon_256x256.png`, `icon_512x512.png`, and the `@2x` variants (`icon_16x16@2x.png` through `icon_512x512@2x.png`). Then run:
  ```bash
  iconutil -c icns AppIcon.iconset -o scripts/AppIcon.icns
  ```
  and rebuild the app.

Either way, the first time the user runs the app and turns the PowerMate dial, macOS will show the **“would like to control this computer using accessibility features”** (or Input Monitoring) dialog. The user must click **Open System Settings** and enable your app under **Privacy & Security → Input Monitoring** (or **Accessibility**). This is required by macOS; there is no way to avoid this one-time step.

## 7. Optional: Installer package (.pkg)

To install to `/Applications` via an installer:

```bash
pkgbuild --identifier com.example.PowerMateAgent \
  --install-location /Applications \
  --root .build/release \
  --scripts scripts/pkg-scripts \
  PowerMateAgent-1.0.0.pkg
```

You would then sign and notarize the **.pkg** with `productbuild` / `productsign` and `notarytool submit` on the .pkg. A **pkg-scripts** folder can run a postinstall script that tells the user to grant Input Monitoring (e.g. open System Settings to the right pane).

## 8. Summary checklist

| Step | What you need |
|------|----------------|
| Build app | `./scripts/build-app.sh` |
| Sign | Developer ID Application cert, `codesign … --options runtime "…app"` |
| Notarize | Apple ID, team ID, app-specific password, `xcrun notarytool submit` |
| Staple | `xcrun stapler staple "…app"` (or `.dmg`) |
| User permission | User enables app in **Input Monitoring** (or Accessibility) once |

The dialog you saw (“Cursor would like to control this computer…”) will appear for **your** signed app the first time the user uses the dial; after they allow it, no further prompts are needed for that app.

---

## 9. CrowdStrike Falcon (and other EDR) quarantine

CrowdStrike Falcon and similar endpoint security products often **quarantine** unsigned or unnotarized macOS apps, or apps that inject input (keyboard/mouse), because they match heuristic or behavioral rules. You can reduce false positives and give users a path to run the app.

### Prevention (what you do)

| Step | Why it helps |
|------|----------------|
| **Sign** with a **Developer ID Application** certificate | Identifies you as a known publisher; many EDRs trust signed code. |
| **Notarize** and **staple** the app (or DMG) | Apple has scanned the binary; notarization is a strong trust signal. |
| **Ship the notarized build** (don't ship debug or ad-hoc signed builds) | Debug/unsigned builds are much more likely to be quarantined. |

There is no way to "pre-approve" your app with every EDR. Signing and notarization are the best way to reduce quarantines; some organizations may still block or quarantine until they add an exclusion.

### If the build is quarantined

- **Restore:** In CrowdStrike Falcon, the user (or admin) can restore the file from quarantine. Exact steps depend on the organization's Falcon configuration and policies.
- **Whitelist / exclusion:** A Falcon admin can add an **exclusion** so your app is not quarantined again:
  - **Path-based:** e.g. `/Applications/PowerMate Agent.app` or the path where users install the app.
  - **Hash-based:** some policies allow excluding by file hash (SHA-256) of the signed binary.
  - In Falcon Console: **Configuration** → **File Exclusions** (or **Prevention** → **Exclusions**) → create an exclusion for macOS with the app path or hash.
- **Report a false positive:** If your app is signed and notarized and you believe it was wrongly flagged, you can report it to CrowdStrike (e.g. through your account team or [CrowdStrike Support](https://www.crowdstrike.com/support/)); they may whitelist the hash or adjust detection. Some EDR vendors also accept samples via their developer or support portals.

### What to tell your users

If you distribute to organizations that use CrowdStrike (or similar):

1. **Use the signed, notarized build** from your official download (not a local debug build).
2. If the app is quarantined, ask them to **restore it** from the security product's quarantine/history (or contact their IT).
3. If it keeps getting quarantined, their **IT or security team** can add a **path or hash exclusion** for **PowerMate Agent** (or your app name) so it is allowed.

You cannot disable or bypass CrowdStrike on a user's machine; only they or their admin can restore and whitelist.
