import SwiftUI
import RMSMaxCore

enum EmojiCatalog {
    struct Category: Identifiable { let id: String; let title: String; let icon: String; let emoji: [String] }

    private static func list(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

    static let categories: [Category] = [
        Category(id: "smileys", title: "Смайлы", icon: "face.smiling", emoji: list("😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 ☺️ 😚 😙 🥲 😋 😛 😜 🤪 😝 🤑 🤗 🤭 🤫 🤔 🤐 🤨 😐 😑 😶 😏 😒 🙄 😬 🤥 😌 😔 😪 🤤 😴 😷 🤒 🤕 🤢 🤮 🤧 🥵 🥶 🥴 😵 🤯 🤠 🥳 🥸 😎 🤓 🧐 😕 😟 🙁 ☹️ 😮 😯 😲 😳 🥺 😦 😧 😨 😰 😥 😢 😭 😱 😖 😣 😞 😓 😩 😫 🥱 😤 😡 😠 🤬 😈 👿 💀 ☠️ 💩 🤡 👹 👺 👻 👽 👾 🤖 😺 😸 😹 😻 😼 😽 🙀 😿 😾 🙈 🙉 🙊")),
        Category(id: "people", title: "Жесты и люди", icon: "hand.wave", emoji: list("👋 🤚 🖐️ ✋ 🖖 👌 🤌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 🖕 👇 ☝️ 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 👐 🤲 🤝 🙏 ✍️ 💅 🤳 💪 🦾 🦵 🦶 👂 🦻 👃 🧠 🫀 🫁 🦷 🦴 👀 👁️ 👅 👄 👶 🧒 👦 👧 🧑 👱 👨 🧔 👩 🧓 👴 👵 🙍 🙎 🙅 🙆 💁 🙋 🧏 🙇 🤦 🤷 👮 🕵️ 💂 🥷 👷 🤴 👸 👳 👲 🧕 🤵 👰 🤰 🤱 👼 🎅 🤶 🦸 🦹 🧙 🧚 🧛 🧜 🧝 🧞 🧟 💆 💇 🚶 🏃 💃 🕺 👯 🧘")),
        Category(id: "hearts", title: "Сердца и символы", icon: "heart", emoji: list("❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💟 ☮️ ✝️ ☪️ 🕉️ ☸️ ✡️ 🔯 ☯️ ♈ ♉ ♊ ♋ ♌ ♍ ♎ ♏ ♐ ♑ ♒ ♓ ⚛️ ☢️ ☣️ 📴 📳 ✅ ☑️ ✔️ ❌ ❎ ➕ ➖ ➗ ✖️ ♾️ ‼️ ⁉️ ❓ ❔ ❕ ❗ 〰️ ©️ ®️ ™️ #️⃣ 0️⃣ 1️⃣ 2️⃣ 3️⃣ 4️⃣ 5️⃣ 6️⃣ 7️⃣ 8️⃣ 9️⃣ 🔟 🔞 🔴 🟠 🟡 🟢 🔵 🟣 ⚫ ⚪ 🟤 🔺 🔻 🔸 🔹 ⭐ 🌟 ✨ ⚡ 🔥 💥 💫 💦 💨 💯 🆗 🆒 🆕 🆓 🆘 🔔 🔕")),
        Category(id: "animals", title: "Животные и природа", icon: "leaf", emoji: list("🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🐔 🐧 🐦 🐤 🦆 🦅 🦉 🦇 🐺 🐗 🐴 🦄 🐝 🐛 🦋 🐌 🐞 🐜 🕷️ 🦂 🐢 🐍 🦎 🐙 🦑 🦐 🦀 🐡 🐠 🐟 🐬 🐳 🐋 🦈 🐊 🐅 🐆 🦓 🦍 🐘 🦏 🐪 🦒 🦘 🐃 🐂 🐄 🐎 🐖 🐏 🐑 🐐 🦌 🐕 🐩 🐈 🐓 🦃 🕊️ 🐇 🐁 🐀 🐿️ 🦔 🌵 🎄 🌲 🌳 🌴 🌱 🌿 ☘️ 🍀 🎍 🍃 🍂 🍁 🍄 🌾 💐 🌷 🌹 🥀 🌺 🌸 🌼 🌻 🌞 🌝 🌛 🌙 🌎 🌍 🌏 🪐 ☀️ ⛅ ☁️ 🌧️ ⛈️ 🌩️ ❄️ ☃️ ⛄ 🌈 💧 🌊")),
        Category(id: "food", title: "Еда и напитки", icon: "fork.knife", emoji: list("🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🍆 🥑 🥦 🥬 🥒 🌶️ 🌽 🥕 🧄 🧅 🥔 🍠 🥐 🥯 🍞 🥖 🧀 🥚 🍳 🥞 🧇 🥓 🥩 🍗 🍖 🌭 🍔 🍟 🍕 🥪 🌮 🌯 🥗 🍝 🍜 🍲 🍛 🍣 🍱 🥟 🍤 🍙 🍚 🍘 🍥 🥠 🍢 🍡 🍧 🍨 🍦 🥧 🧁 🍰 🎂 🍮 🍭 🍬 🍫 🍿 🍩 🍪 🌰 🥜 🍯 🥛 🍼 ☕ 🍵 🧃 🥤 🍶 🍺 🍻 🥂 🍷 🥃 🍸 🍹 🍾 🧊 🥄 🍴 🍽️")),
        Category(id: "activity", title: "Спорт и занятия", icon: "figure.run", emoji: list("⚽ 🏀 🏈 ⚾ 🥎 🎾 🏐 🏉 🥏 🎱 🏓 🏸 🏒 🏑 🥍 🏏 🥅 ⛳ 🏹 🎣 🤿 🥊 🥋 🎽 🛹 🛼 ⛸️ 🥌 🎿 ⛷️ 🏂 🏋️ 🤼 🤸 ⛹️ 🤺 🤾 🏌️ 🏇 🧘 🏄 🏊 🤽 🚣 🧗 🚴 🚵 🎪 🎭 🎨 🎬 🎤 🎧 🎼 🎹 🥁 🎷 🎺 🎸 🪕 🎻 🎲 ♟️ 🎯 🎳 🎮 🎰 🧩 🏆 🥇 🥈 🥉 🏅 🎖️ 🎗️ 🎫 🎟️ 🎁 🎀 🎊 🎉 🎈 🎂")),
        Category(id: "travel", title: "Путешествия", icon: "airplane", emoji: list("🚗 🚕 🚙 🚌 🚎 🏎️ 🚓 🚑 🚒 🚐 🚚 🚛 🚜 🛵 🏍️ 🚲 🛴 🚨 🚔 🚍 🚘 🚖 🚡 🚠 🚟 🚃 🚋 🚞 🚝 🚄 🚅 🚈 🚂 🚆 🚇 🚊 🚉 ✈️ 🛫 🛬 🛩️ 💺 🚀 🛸 🚁 🛶 ⛵ 🚤 🛥️ 🛳️ ⛴️ 🚢 ⚓ ⛽ 🚧 🚦 🚥 🗺️ 🗿 🗽 🗼 🏰 🏯 🏟️ 🎡 🎢 🎠 ⛲ ⛱️ 🏖️ 🏝️ 🏜️ 🌋 ⛰️ 🏔️ 🗻 🏕️ ⛺ 🏠 🏡 🏢 🏣 🏥 🏦 🏨 🏪 🏫 🏬 🏭 ⛪ 🕌 🕍 ⛩️ 🌅 🌄 🌃 🌆 🌇 🌉 🌌")),
        Category(id: "objects", title: "Предметы", icon: "lightbulb", emoji: list("⌚ 📱 💻 ⌨️ 🖥️ 🖨️ 🖱️ 💽 💾 💿 📀 📷 📸 📹 🎥 📞 ☎️ 📺 📻 🎙️ ⏰ ⏳ ⌛ 📡 🔋 🔌 💡 🔦 🕯️ 💸 💵 💴 💶 💷 💰 💳 💎 ⚖️ 🔧 🔨 ⚒️ 🛠️ ⛏️ 🔩 ⚙️ 🧱 ⛓️ 🧲 🔫 💣 🧨 🔪 🗡️ ⚔️ 🛡️ 🚬 ⚰️ 🔮 📿 💈 ⚗️ 🔭 🔬 💊 💉 🧬 🦠 🧫 🧪 🌡️ 🧹 🧺 🧻 🚽 🚰 🚿 🛁 🧼 🧽 🔑 🗝️ 🚪 🛋️ 🛏️ 🧸 🖼️ 🛍️ 🛒 🎁 🎈 ✉️ 📦 📜 📃 📄 📊 📈 📉 📋 📌 📍 📎 🖇️ 📏 📐 ✂️ 🗃️ 🗄️ 🗑️ 🔒 🔓 🔏 🔐")),
    ]
}

/// Emoji and stickers in one panel, like the official client: tabs, categories, recents.
struct EmojiStickerPanel: View {
    let onEmoji: (String) -> Void
    let onSticker: (Sticker) -> Void
    @State private var tab = 0
    @State private var category = "recent"
    @AppStorage("recentEmoji") private var recentRaw = ""

    private var recent: [String] { recentRaw.split(separator: " ").map(String.init) }
    private let columns = Array(repeating: GridItem(.flexible(minimum: 28), spacing: 2), count: 8)

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $tab) {
                Text("Эмодзи").tag(0)
                Text("Стикеры").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8).padding(.top, 8)

            if tab == 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        tabIcon(id: "recent", icon: "clock")
                        ForEach(EmojiCatalog.categories) { c in tabIcon(id: c.id, icon: c.icon, title: c.title) }
                    }
                    .padding(.horizontal, 8)
                }
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(current, id: \.self) { e in
                            Button { pick(e) } label: { Text(e).font(.system(size: 24)).frame(width: 34, height: 34) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    if current.isEmpty {
                        Text("Здесь будут последние эмодзи").font(.caption).foregroundStyle(.secondary).padding()
                    }
                }
            } else {
                StickerPicker(onPick: onSticker)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        // One fixed size for both tabs, so the popover does not grow (and slide off the screen) when switching.
        .frame(width: 360, height: 420)
    }

    private var current: [String] {
        category == "recent" ? recent : (EmojiCatalog.categories.first { $0.id == category }?.emoji ?? [])
    }

    private func tabIcon(id: String, icon: String, title: String = "Недавние") -> some View {
        Button { category = id } label: {
            Image(systemName: icon)
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(category == id ? Color.accentColor.opacity(0.25) : .clear))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func pick(_ e: String) {
        var list = recent.filter { $0 != e }
        list.insert(e, at: 0)
        recentRaw = list.prefix(24).joined(separator: " ")
        onEmoji(e)
    }
}
