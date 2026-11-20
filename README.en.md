<div align="center">
🇷🇺 <a href="README.md">Русский</a> • 🇬🇧 <b>English</b>
</div>

<div align="center">

# 💬 RMS MAKS

**A native, lightweight client for the MAX messenger on macOS and iOS: no telemetry, end-to-end encryption between friends, and a familiar Telegram-style interface.**

Written from scratch in pure Swift: no Electron, no Chromium, no third-party tracking SDKs. It talks to MAX directly,
sends no data about you anywhere, and adds what the official apps do not offer: encryption of your conversations on your side,
tracker blocking and open source code you can audit.

[![Platform](https://img.shields.io/badge/macOS-14%2B-lightgrey?logo=apple)](#download)
[![iOS](https://img.shields.io/badge/iOS-17%2B-lightgrey?logo=apple)](#download)
[![Swift](https://img.shields.io/badge/Swift-native-F05138?logo=swift&logoColor=white)](#under-the-hood)
[![Telemetry](https://img.shields.io/badge/telemetry-none-brightgreen)](#privacy)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

[Why](#why-rms-maks) • [Features](#features) • [Under the hood](#under-the-hood) • [Download](#download) • [Privacy](#privacy) • [Limitations](#limitations) • [Build](#build-and-contribute) • [License](#license) • [Support](#support-the-author)

</div>

---

> ### 🔒 Privacy promise
> RMS MAKS does **not** collect your messages, contacts, files, keystrokes or usage statistics. The client has no analytics, no device
> data collection and no background pings, and requests from mini-app trackers are blocked. The only contact with RMS servers is
> the check for new versions against a cryptographically signed manifest. The source code is open, so you can verify all of this.

> RMS MAKS is an unofficial client. It is not affiliated with the MAX developers and is not endorsed by them.
>
> **The interface of the app is currently in Russian only** (MAX itself is a Russian-language messenger).

## Why RMS MAKS

- **Zero telemetry and tracker blocking.** Analytics, device metrics and background sends are removed entirely. A built-in transport-level
  filter blocks mini-app and third-party trackers (AppMetrica, MyTracker, Mail.ru, Yandex Metrica and others). The list of blocked
  domains is visible in the settings and can be extended.
- **Native Swift, not a browser wrapper.** The installers are small (about 27 MB for macOS and about 11 MB for iOS) and in everyday use the
  app takes roughly 40–60 MB of memory (measured on macOS). It starts instantly and behaves like a native app.
- **End-to-end encryption between friends.** Conversations and calls between RMS MAKS users are encrypted on the sender's device and
  decrypted only on the recipient's (ChaCha20-Poly1305, Curve25519 keys, chat password through Argon2id). Switched on with a toggle in the chat.
- **Open source you can audit.** GNU AGPLv3: you can read, verify and change the code, but you cannot take it into a closed product.

## Features

### Chats and messages
- Private and group chats, channels with comments, folders and chat filters, pinned messages.
- Replies, forwarding (including several messages at once), editing, deleting for yourself and for everyone, multi-message selection.
- **Telegram-style formatting**: bold, italic, underline, strikethrough, quote, monospace, links and `@mentions`, with keyboard shortcuts
  (⌘B, ⌘I, ⌘U, ⇧⌘X, ⇧⌘., ⇧⌘M, ⌘K) and a Formatting menu.
- A proper composer: Return sends, Shift+Return starts a new line (or the other way round, by setting).
- **Reactions** with the set defined for the chat, and **polls**: create (anonymous, multiple answers, revoting) and vote.
- **Scheduled messages**, per-chat drafts, retry after a failed send, search in a chat and across all messages, a theme for each chat.
- Presence: typing, online status, delivery and read ticks.

### Media
- Photos, video, files, voice messages with a waveform, **round video messages** (record and play), pasting an image from the clipboard.
- **Stickers and emoji**: a searchable panel, sticker pack management (add by link, remove), **animated emoji** (rendered on the device).
- A **smart Telegram-style media cache**: a size limit with cleaning by type, prefetching of round videos, voice messages and photos, auto-download rules.
- Stories: view and publish.

### Calls
- Audio and video calls, **group conferences by link** (create, share, join), screen sharing, call history.
- Calls are recorded in the chat feed (duration, missed, cancelled), with dialing and hang-up sounds.
- An encrypted call mode between RMS MAKS users.

### Privacy and security
- **App lock** with Touch ID / Face ID; session data and keys are stored in the system Keychain.
- MAX account privacy settings: who can find you by phone number, call you, invite you to chats, see your number and online status.
- A **login password** (two-factor protection): enable, change, remove, with a hint and a recovery e-mail.
- Transparent permissions: the settings show why each permission is needed (notifications, microphone, camera, contacts, screen recording),
  what state it is in and how to enable it.

### System integration
- Native notifications with sound, a menu bar icon, a badge counter on the app icon.
- MAX links open in the app (the `max://` scheme): conferences, chat invitations, profiles, sticker packs.
- A chat and contact info panel, a message menu with reactions, quick switching between chats.
- Automatic updates with cryptographic signature verification.

## Under the hood

For engineers and anyone who wants to know what they are running:

- **Swift and SwiftUI**, one codebase for macOS 14+ and iOS 17+. The project is split into `RMSMaxCore` (protocol, networking, cryptography,
  calls, application state; no UI) and `RMSMaxApp` (the interface). The core has unit tests that run offline (`swift test`).
- **Only two third-party dependencies**, both pinned to exact versions: the LiveKit build of Google WebRTC (calls: audio, video, screen
  sharing) and Lottie (animated emoji). Everything else is Apple frameworks and code in this repository.
- **Cryptography**: ChaCha20-Poly1305 and Curve25519 (X25519 for key agreement, Ed25519 for signatures) from Apple CryptoKit; Argon2id for
  password-derived keys is implemented in this repository. No third-party crypto library.
- **Secrets** live in the system Keychain; the app can be locked behind Touch ID / Face ID.
- **Updates** are delivered as a manifest signed with minisign (Ed25519); the app verifies the signature and the SHA-256 of the installer
  against a public key pinned in the code before it installs anything. macOS builds are signed with an Apple Developer ID and notarized.
- **No telemetry code to remove**: there is none to begin with, and a transport-level filter additionally blocks known tracker hosts.

## Download

> The installers are served from the official RMS update server. Product page: [rms-ds.com](https://rms-ds.com/products/rms-maks).

### macOS (macOS 14+, Apple Silicon and Intel)

1. Download the [`.dmg` installer](https://update.rms-ds.com/get/rms-maks/dmg).
2. Open it and drag RMS MAKS to Applications.
3. The app is signed with an Apple Developer ID certificate and notarized by Apple: it opens without Gatekeeper warnings and then
   updates itself.

### iOS (iOS 17+, via SideStore)

iOS builds are distributed outside the App Store. Your SideStore signs the app with its own free certificate, so no RMS developer
signature ends up on your device. The app uses a single App ID and contains no extensions.

1. Add the RMS source to SideStore with one tap: [`sidestore://source?url=https://update.rms-ds.com/altstore/rms-maks.json`](sidestore://source?url=https://update.rms-ds.com/altstore/rms-maks.json)
   — or add it manually under **Sources**, using this address:

   ```
   https://update.rms-ds.com/altstore/rms-maks.json
   ```

2. Install RMS MAKS from the added source.
3. SideStore will offer fresh versions by itself.

If you only need the file: [`.ipa`](https://update.rms-ds.com/get/rms-maks/ipa) (unsigned). A detailed step-by-step guide is in
[ipa-install.md](ipa-install.md) (in Russian).

## Privacy

- **No data collection.** Messages, contacts, files, keystrokes and usage statistics are neither collected nor sent.
- **Direct connection.** The client talks to the MAX servers and to your contacts, with no intermediaries.
- **Update check.** The app contacts `update.rms-ds.com` only to learn about new versions, and installs them only if the manifest
  signature is valid.
- **Everything is local.** The media cache, drafts and settings are stored on your device; the cache can be limited and cleared in the settings.

## Limitations

- **Notifications on iOS.** Without Apple Push (APNs), an app installed through SideStore shows notifications while it is running or
  active in the background. When the system has unloaded it, notifications do not arrive.
- **MAX server specifics.** The server does not provide the full list of pinned messages or a "who viewed" list in groups, so the
  interface does not show them. Animated emoji are not available to every account: the server decides.
- **Encryption works only between RMS MAKS users.** A contact using the official app will see service text instead of the message.
- **The interface language is Russian.**

## Build and contribute

You can build the app from source following [BUILDING.md](BUILDING.md); how to propose a fix or an idea is described in
[CONTRIBUTING.md](CONTRIBUTING.md). Both documents are currently in Russian, and issues in English are welcome. To report a
vulnerability, **do not open a public issue**: write to [support@rms-ds.com](mailto:support@rms-ds.com) (see [SECURITY.md](SECURITY.md)).

## License

The source code is open under the **[GNU Affero General Public License v3.0](LICENSE)** (`AGPL-3.0-only`).

You can read, run, change and distribute the code. Any derivative work, including one run as a network service, must remain open
under the same licence: this code cannot be taken into a closed product. Third-party components and their licences are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Support the author

RMS MAKS is developed independently, with no ads and no data collection. If the app is useful to you, you can support its development here:

<div align="center">

[![Boosty](https://img.shields.io/badge/Boosty-support-F15F2C)](https://boosty.to/rmsds/donate)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-support-FF5E5B?logo=kofi&logoColor=white)](https://ko-fi.com/maxramas)

</div>

Other contributions matter too: tell others about the project, report a bug, suggest an idea.

## Support and feedback

Bugs and feature requests: open an [issue](../../issues) or write to [support@rms-ds.com](mailto:support@rms-ds.com) · [rms-ds.com](https://rms-ds.com)

<div align="center">

© RMS Digital Services · [AGPLv3](LICENSE)

</div>
