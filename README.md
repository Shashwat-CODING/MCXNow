# 📈 MCXNow

A modern, real-time Multi Commodity Exchange (MCX) market viewer application built with Flutter that provides live updates using Server-Sent Events (SSE).

<div align="center">
  <img src="https://raw.githubusercontent.com/yourusername/stock_app/main/assets/mcx-logo.png" alt="MCXNow Logo" width="200">
  <p><em>Real-time MCX Market Data at Your Fingertips</em></p>
</div>

## ✨ Features

- 🔄 Real-time stock price updates using SSE
- 📱 Cross-platform support (iOS, Android, Web)
- 💾 Local data persistence using SharedPreferences
- 🎨 Modern Material Design UI
- 📊 Interactive stock price charts
- 🌙 Dark mode support

## 🛠️ Tech Stack

- **Framework:** Flutter 3.x
- **Language:** Dart 3.8+
- **State Management:** Built-in StatefulWidget
- **Network:** HTTP package for API calls
- **Real-time Updates:** Server-Sent Events (SSE)
- **Local Storage:** SharedPreferences
- **Build System:** Gradle (Android), Xcode (iOS)

## 🚀 Getting Started

### Prerequisites

- Flutter SDK 3.x or higher
- Dart SDK 3.8.1 or higher
- Android Studio / Xcode (for mobile development)
- A compatible IDE (VS Code recommended)

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/mcxnow.git
   cd mcxnow
   ```

2. Install dependencies:
   ```bash
   flutter pub get
   ```

3. Run the app:
   ```bash
   flutter run
   ```

## 📱 Building for Production

### Android

1. Create a `key.properties` file at `android/key.properties`:
   ```properties
   storeFile=/absolute/path/to/release.keystore
   storePassword=YOUR_STORE_PASSWORD
   keyAlias=YOUR_KEY_ALIAS
   keyPassword=YOUR_KEY_PASSWORD
   ```

2. Place your keystore at the path in `storeFile` (e.g., `android/app/release.keystore`).

3. Build signed APK/AAB:
   ```bash
   flutter build apk --release
   # or
   flutter build appbundle --release
   ```

### iOS

1. Open `ios/Runner.xcworkspace` in Xcode
2. Configure signing in Xcode
3. Build the app:
   ```bash
   flutter build ios --release
   ```

## 🔧 Configuration

The app can be configured through environment variables or configuration files. Check the documentation for more details.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 👥 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
