# RMS MAKS

Нативный мультиплатформенный клиент для **Max** на **Swift 5.10+ / SwiftUI** для **macOS 14+ (Apple Silicon)**, **iOS 17+** и **iPadOS 17+**.

Проводной протокол (Mobile TLS MsgPack + LZ4, WebSocket JSON), сквозное шифрование 1:1 и групп, зашифрованные звонки (SFrame-совместимый AES-GCM) и криптография полностью реализованы на нативном Swift (`CryptoKit`, `Network.framework`, `Compression`, `LocalAuthentication`, `UserNotifications`, `Security`).

---

## Архитектура

### `RMSMaxCore` (`Sources/RMSMaxCore/`)
- **Models**: `Models/MaxModels.swift` — `JSONValue`, `MaxIdentity` (mobile/web), `MaxRequest`/`MaxResponse`, `SyncState`, `MaxChat`, `MaxMessage`, `MaxContact`, `MaxAccount`, `ChatE2ESettings`, `ActiveCallState`, `MediaDescriptor`.
- **Protocol**:
  - `Protocol/MsgPack.swift` — кодировщик/декодер MessagePack с поддержкой бинарных ключей протокола Max (`mode`, `chatCacheFingerprint`, `chatsCountGroups`, `wave`, `previewData`).
  - `Protocol/LZ4Decompressor.swift` — блочный декомпрессор LZ4 для сжатых ответов синхронизации.
  - `Protocol/ApkFingerprint.swift` — генерация 96-байтного SHA-256 fingerprint APK (`26.31.0`, `26.30.1`, `26.30.0`, `26.11.1`).
- **Network**:
  - `Network/MaxTransport.swift` — `MobileTLSTransport` (`NWConnection` TLS 1.2+ на `api2.oneme.ru:443` с корневым сертификатом Минцифры / Russian Trusted Root CA + системным доверием), `WebSocketTransport` (`wss://ws-api.oneme.ru/websocket`), `MaxVoiceChannel` (сигналинг звонков).
  - `Network/MaxClient.swift` — actor-клиент API Max (авторизация, SMS/2FA/QR, синк чатов и истории, контакты, файлы, звонки, групповые конференции); **`telemetryMode` по умолчанию `"disabled"`**, внешние IP-пробы отсутствуют.
- **Crypto**:
  - `Crypto/AsymmetricCrypto.swift` — Ed25519 + X25519 (`0x01` init, `0x02` accept, `0x03` group key announce, `0x04` group key wrap в wire-формате `rmp_serde`).
  - `Crypto/SymmetricCrypto.swift` — ChaCha20-Poly1305, чистый Swift BLAKE2b + RFC 9106 Argon2id (`m=19456`, `t=2`, `p=1`, `tagLen=32`), медиа-конверт `MediaCrypto` (`0x8F 0x3D` + legacy).
  - `Crypto/E2EProtocol.swift` — заголовок флагов, соль чата, raw deflate (`COMPRESSION_ZLIB`), упаковка и распаковка текстовых, медиа- и управляющих пакетов.
  - `Crypto/Obfuscation.swift` — китайская обфускация (`U+4E00..`) и Base64-режим.
  - `Crypto/EmojiFingerprint.swift` — 256-эмодзи отпечаток ключей 1:1 и звонков.
- **Calls**:
  - `Calls/CallFrameHeader.swift` — вычисление незашифрованного префикса для SFU/WebRTC (Opus `1`, VP8 `10`/`3`, H.264 Annex-B SPS/PPS/IDR/slice).
  - `Calls/CallEncryption.swift` — SFrame-совместимое шифрование медиакадров (`AES-GCM-128`, `HKDF-SHA256`), эфемерный `P-256 ECDH` для 1:1 звонков и симметричный групповой режим.
- **Services**:
  - `Services/SecureStore.swift` — шифрованное локальное хранилище (`RMSX1` ChaCha20-Poly1305) с мастер-ключом в Keychain (и защищённым локальным fallback для CLI-тестов без бандла), плюс `TrackerBlocker` (`sdk-api.apptracer.ru`, `mytracker.com`, `mc.yandex.ru`, `stat.oneme.ru` и др.).
  - `Services/NotificationService.swift` — нативные системные уведомления (`UNUserNotificationCenter`), группировка по `threadIdentifier` чата, бейдж на иконке приложения.
  - `Services/AppStore.swift` — координатор состояния (`@MainActor ObservableObject`), биометрическая блокировка (`LAContext` Touch ID / Face ID), авто-обработка E2E-рукопожатий и ротации групповых ключей, управление звонками.

### `RMSMaxApp` (`Sources/RMSMaxApp/`)
- `RMSMaxApp.swift` — точка входа SwiftUI (WindowGroup + macOS Settings scene).
- `ContentView.swift` — адаптивный `NavigationSplitView` для macOS, iPadOS и iPhone (вкладки «Чаты», «Контакты», экран блокировки, индикатор звонка).
- `AuthView.swift` — вход по номеру телефона/SMS/2FA, QR-коду или токену с выбором транспорта.
- `ChatDetailView.swift` — переписка, расшифровка/отправка E2E-сообщений и паролей, 1:1 рукопожатия и групповое E2E, вложения, реакции, запуск аудио/видеозвонка.
- `CallOverlayView.swift` — панель активного/входящего звонка с SFrame-отпечатком, таймером, mute/camera/hangup.
- `SettingsView.swift` — настройки аккаунта, транспорта, приватности (блоклист трекеров, режим телеметрии), уведомлений, Touch ID / Face ID, сброс данных.

---

## Сборка и тесты

### Swift Package Manager (macOS)
```bash
# Прогнать все 11 модульных тестов RMSMaxCoreTests
swift test

# Собрать release-артефакты
swift build -c release
```

### Xcode (`macOS` / `iOS` / `iPadOS`)

Проект `RMSMax.xcodeproj` генерируется из `project.yml` через **XcodeGen**:

```bash
xcodegen generate
open RMSMax.xcodeproj
```

Сборка из командной строки без подписи (для проверки):
```bash
# macOS (.app для Apple Silicon)
xcodebuild -project RMSMax.xcodeproj -scheme RMSMax_macOS -configuration Release CODE_SIGNING_ALLOWED=NO build

# iOS / iPadOS (iphoneos SDK, universal: iPhone + iPad)
xcodebuild -project RMSMax.xcodeproj -scheme RMSMax_iOS -configuration Release -sdk iphoneos -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

### Установка на MacBook M2 и iPhone / iPad с Apple Developer Account
1. Откройте `RMSMax.xcodeproj` в Xcode.
2. Выберите нужный таргет (**`RMSMax_macOS`** для MacBook или **`RMSMax_iOS`** для iPhone/iPad).
3. В разделе **Signing & Capabilities** выберите свою **Team** и при необходимости задайте уникальный `Bundle Identifier` (по умолчанию `dev.rms.maks.macos` / `dev.rms.maks.ios`).
4. Выберите ваше устройство (My Mac или подключённый iPhone / iPad) и нажмите **Run (`⌘R`)** или **Product → Archive** для установки/экспорта.
