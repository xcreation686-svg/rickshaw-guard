# RickshawGuard

A small Flutter app that lets an e-rickshaw owner **secure their own** Bluetooth BMS:

- **Restore power** if someone cuts the discharge output.
- **Watch & auto-restore** — if the output is switched off while you ride, turn it back on automatically.
- **Set a password** on BMS families that support one, so strangers can't connect.

You pick your own device and can "remember" it. This is the same kind of control the manufacturer's own BMS app gives you — just focused on keeping your rickshaw running and locked to you.

> **Save any password you set.** If you forget it, you can lock yourself out of your own BMS.

---

## Which BMS do you have? (This decides the strategy)

| BMS family | Password? | What to do |
|---|---|---|
| **JBD / Xiaoxiang / Overkill** (most common, cheapest) | Usually **none** | The attack works because there's *no authentication*. Use **Watch & auto-restore**, and physically mitigate Bluetooth (shield it, relocate it, or swap in a BMS that has auth). This app implements read + power-on for JBD. |
| **JK-BMS (Jikong)** | **Yes** | Setting a strong password is a real fix. Different protocol (header `55 AA EB 90`). Add a `JkProtocol` class — see below. |
| **Daly / ANT / others** | Varies | Confirm the exact protocol for your model before writing password bytes. |

**How to identify yours:** check the sticker on the BMS, and note which app the seller told you to install (the app name usually maps to the family: "Xiaoxiang" = JBD, "JK BMS"/"JIKONG" = JK-BMS).

This scaffold implements **JBD/Xiaoxiang** concretely. For JBD there is normally no password to change, so that feature is disabled with an on-screen note — I did **not** invent password bytes, because sending wrong frames to a BMS can misbehave.

---

## Setup

`pubspec.yaml` dependencies:

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_blue_plus: ^1.32.0
  permission_handler: ^11.3.0
  shared_preferences: ^2.2.0
```

`android/app/src/main/AndroidManifest.xml` — inside `<manifest>`, before `<application>`:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<!-- Needed for BLE scan on Android 11 and below -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"
    android:maxSdkVersion="30" />
```

Set `minSdkVersion 21` (or higher) in `android/app/build.gradle`.

---

## Build the APK

You need Flutter installed (https://docs.flutter.dev/get-started/install). Then:

```bash
flutter create rickshaw_guard          # scaffold a project (once)
# copy lib/main.dart and the pubspec deps into it, edit the manifest
cd rickshaw_guard
flutter pub get
flutter build apk --release            # output: build/app/outputs/flutter-apk/app-release.apk
```

Install `app-release.apk` on the phone (enable "install from unknown sources").
For quick testing on a plugged-in phone: `flutter run`.

---

## Using it while riding

1. **Scan** and tap your BMS (match the Bluetooth name on your sticker), then pin it as "my rickshaw."
2. Turn on **Watch & auto-restore** and keep the screen on. If someone cuts your output, the app switches it back on.
3. If your BMS supports a password (e.g. JK-BMS), set a strong one so strangers can't connect at all.

Auto-restore needs the app connected, so it works best with the screen on. For always-on protection you'd add a foreground service that keeps the BLE link alive in the background — a good next step, but not included here to keep the scaffold simple.

---

## Adding another BMS family

`main.dart` defines an abstract `BmsProtocol`. Implement a new class (e.g. `JkProtocol`) with:

- `serviceHint / notifyHint / writeHint` — the BLE UUID substrings for that BMS,
- `cmdReadStatus()`, `cmdPowerOn()`, and (if it has one) `cmdSetPassword()`,
- `feed()` to reassemble streamed chunks into whole frames, and `parseStatus()`.

Then set `final BmsProtocol _proto = JkProtocol();` in `DeviceScreen`. Only fill in `cmdSetPassword()` once you've confirmed the exact frame for that model.
