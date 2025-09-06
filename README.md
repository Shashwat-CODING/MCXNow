# stock_app

Live stock viewer with SSE updates.

## Build & Sign (Android)

1) Create a `key.properties` file at `android/key.properties`:

```properties
storeFile=/absolute/path/to/release.keystore
storePassword=YOUR_STORE_PASSWORD
keyAlias=YOUR_KEY_ALIAS
keyPassword=YOUR_KEY_PASSWORD
```

2) Place your keystore at the path in `storeFile` (e.g., `android/app/release.keystore`).

3) Build signed APK/AAB:

```bash
flutter build apk --release
# or
flutter build appbundle --release
```

Signing is configured in `android/app/build.gradle.kts`. If `key.properties` is missing, release falls back to debug signing so local runs still work.
