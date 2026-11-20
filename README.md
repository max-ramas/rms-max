# RMS MAKS

Нативный клиент мессенджера MAX для **macOS 14+** (Apple Silicon и Intel), **iOS 17+** и **iPadOS 17+** на Swift/SwiftUI — без телеметрии, со сквозным шифрованием и звонками, совместимыми с официальным клиентом.

## Скачать

| Платформа | Файл | Ссылка |
| --- | --- | --- |
| macOS | DMG, подписан Developer ID и нотаризован Apple | https://update.rms-ds.com/get/rms-maks/dmg |
| iPhone / iPad | IPA без подписи (SideStore / AltStore) | https://update.rms-ds.com/get/rms-maks/ipa |

Ссылки всегда ведут на последнюю стабильную версию. Все версии и примечания к выпуску: https://update.rms-ds.com/v1/rms-maks/releases. Релизы подписаны ключом minisign RMS; на GitHub они не публикуются.

**macOS.** Откройте DMG и перетащите RMS MAKS в «Программы». Приложение нотаризовано Apple и открывается обычным двойным щелчком.

**iPhone / iPad.** Установка через SideStore — пошагово в [ipa-install.md](ipa-install.md). Приложение переподписывается на устройстве, Apple-аккаунт разработчика не нужен.

## Возможности

- **Переписка:** чаты, группы, каналы, история, поиск, вложения (фото, видео, файлы), голосовые в формате официального клиента (Ogg/Opus), стикеры, опросы, папки, закрепление, пересылка, редактирование, удаление у всех, жалобы.
- **Сквозное шифрование (RMS ↔ RMS):** сообщения и медиа (X25519/Ed25519, ChaCha20-Poly1305, Argon2id), групповые ключи, сверка эмодзи-отпечатком.
- **Звонки (совместимы с официальным MAX):** аудио и видео 1:1, групповые звонки и конференции по ссылке; прямое соединение с TURN и автоматический переход на сервер звонков; восстановление связи; чат, поднятая рука, админ-инструменты, зал ожидания и запись; демонстрация экрана на Mac; E2E-звонки между двумя RMS MAKS; CallKit; выбор микрофона, динамиков и камеры; история звонков.
- **Аккаунт:** вход по SMS-коду, звонком или по QR-коду, 2FA; контакты и чёрный список; профиль; управление группами и ссылками-приглашениями; истории; боты (кнопки и `/start`).

## Приватность

- Никакой статистики, логов и метрик: отправка телеметрии MAX и SDK звонков вырезана, трекеры заблокированы.
- Недавние стикеры, кэш медиа и ключи хранятся только на устройстве (шифрованное хранилище, мастер-ключ в Keychain).
- Мини-приложения, передача геопозиции и номера телефона ботам не поддерживаются намеренно.
- Расшифровка голосовых выключена по умолчанию: её выполняет сервер MAX.

## Сборка

```bash
xcodegen generate          # проект RMSMax.xcodeproj из project.yml
swift test                 # модульные тесты ядра
```

```bash
# macOS (универсальная, подпись Developer ID)
xcodebuild -project RMSMax.xcodeproj -scheme RMSMax_macOS -configuration Release -destination 'generic/platform=macOS' build

# iOS / iPadOS без подписи (для SideStore)
xcodebuild -project RMSMax.xcodeproj -scheme RMSMax_iOS -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Зависимость WebRTC — сборка LiveKit (`livekit/webrtc-xcframework`, BSD): выбор аудиоустройств, шифрование кадров, захват экрана.

## Выпуск версии

1. Поднять `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` в `project.yml`, собрать DMG и IPA локально.
2. Нотаризовать: приложение (`ditto` в zip → `notarytool submit --keychain-profile notarytool-profile --wait` → `stapler staple`), затем собрать DMG, подписать, нотаризовать и тоже застеплить.
3. Подписать манифест `rms-release manifest` (ключ `release-key`), проверить `rms-release verify --check-artifacts`.
4. Выложить на сервер обновлений скриптом `server-release-script` из `deploy-repo` (раскладка релиза, проверка здоровья и каталога, автооткат). Байты уже опубликованной версии сервер менять не даёт — каждое изменение выходит новой версией.
