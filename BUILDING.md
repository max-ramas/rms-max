# Сборка RMS MAKS из исходников

## Что нужно

- macOS 14 или новее и Xcode 15.3+ (проект собирается и на новых версиях; разработка идёт на актуальном Xcode).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`. Файл проекта `RMSMax.xcodeproj` в репозитории не хранится, он создаётся из `project.yml`.
- Доступ к GitHub для загрузки зависимостей (Swift Package Manager).

## Быстрый старт

```bash
git clone https://github.com/max-ramas/rms-max.git
cd rms-max
xcodegen generate     # создаёт RMSMax.xcodeproj из project.yml
swift test            # модульные тесты ядра (без сети)
open RMSMax.xcodeproj # схемы RMSMax_macOS и RMSMax_iOS
```

## Сборка из командной строки

```bash
# macOS (универсальная: Apple Silicon + Intel), без подписи Developer ID — для локального запуска
xcodebuild -project RMSMax.xcodeproj -scheme RMSMax_macOS -configuration Release \
  -destination 'generic/platform=macOS' CODE_SIGN_IDENTITY="-" build

# iOS / iPadOS без подписи (такой файл ставится через SideStore или AltStore, они подписывают его сами)
xcodebuild -project RMSMax.xcodeproj -scheme RMSMax_iOS -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Чтобы собрать `.ipa`, положите получившийся `RMS MAKS.app` в папку `Payload` и заархивируйте её в zip с расширением `.ipa`.

## Подпись своей сборки

В `project.yml` указан `DEVELOPMENT_TEAM` автора. Если вы собираете форк со своей подписью, замените его на свой Team ID и
идентификатор пакета `PRODUCT_BUNDLE_IDENTIFIER`. Без подписи приложение запускается локально (`CODE_SIGN_IDENTITY="-"`), но macOS
может запрашивать разрешения заново при каждой пересборке.

## Устройство репозитория

| Путь | Что там |
| --- | --- |
| `Sources/RMSMaxCore` | ядро без интерфейса: протокол MAX, сеть, шифрование, звонки, состояние (`AppStore`) |
| `Sources/RMSMaxApp` | интерфейс на SwiftUI для macOS и iOS |
| `Tests/RMSMaxCoreTests` | модульные тесты ядра |
| `XcodeSupport` | иконки, `Info.plist`, entitlements |
| `project.yml` | описание проекта для XcodeGen |

## Зависимости

- [LiveKit WebRTC xcframework](https://github.com/livekit/webrtc-xcframework) — звонки (аудио, видео, демонстрация экрана).
- [lottie-ios](https://github.com/airbnb/lottie-ios) — анимодзи.

Лицензии зависимостей — в [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Сетевые тесты

По умолчанию `swift test` не обращается к сети. Несколько проверок на живых серверах включаются переменной `RMS_NETWORK_TESTS=1`;
они не используют ни аккаунт, ни ключи, но обращаются к реальным адресам MAX, поэтому запускайте их осознанно.
