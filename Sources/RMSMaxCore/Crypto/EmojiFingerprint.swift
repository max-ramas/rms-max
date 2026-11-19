import Foundation
import CryptoKit

public enum EmojiFingerprint {
    public static let table: [String] = [
        "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼",
        "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔",
        "🐧", "🐦", "🐤", "🦆", "🦅", "🦉", "🦇", "🐺",
        "🐗", "🐴", "🦄", "🐝", "🐛", "🦋", "🐌", "🐞",
        "🐜", "🦟", "🐢", "🐍", "🦎", "🐙", "🦑", "🦐",
        "🦞", "🦀", "🐡", "🐠", "🐟", "🐬", "🐳", "鲨",
        "🐊", "🐅", "🐆", "🦓", "🦍", "🐘", "🦛", "🦏",
        "🐪", "🐫", "🦒", "🦘", "🐃", "🐂", "🐄", "🐎",
        "🐖", "🐏", "🐑", "🐐", "🦌", "🐕", "🐩", "🐈",
        "🐓", "🦃", "🦚", "🦜", "🦢", "🦩", "🕊", "🐇",
        "🦝", "🦨", "🦡", "🦦", "🦥", "🐁", "🐀", "🐿",
        "🦔", "🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉",
        "🍇", "🍓", "🫐", "🍈", "🍒", "🍑", "🥭", "🍍",
        "🥥", "🥝", "🍅", "🍆", "🥑", "🥦", "🥬", "🥒",
        "🌶", "🌽", "🥕", "🧄", "🧅", "🥔", "🍠", "🥐",
        "🥯", "🍞", "🥖", "🥨", "🧀", "🥚", "🍳", "🧈",
        "🥞", "🧇", "🥓", "🥩", "🍗", "🍖", "🌭", "🍔",
        "🍟", "🍕", "🥪", "🥙", "🧆", "🌮", "🌯", "🥗",
        "🥘", "🍝", "🍜", "🍲", "🍛", "🍣", "🍱", "🥟",
        "🦪", "🍤", "🍙", "🍚", "🍘", "🍥", "🥠", "🍢",
        "🍡", "🍧", "🍨", "🍦", "🥧", "🧁", "🍰", "🎂",
        "🍮", "🍭", "🍬", "🍫", "🍿", "🍩", "🍪", "🌰",
        "🥜", "🍯", "🥛", "☕", "🍵", "🧃", "🥤", "🧊",
        "⚽", "🏀", "🏈", "⚾", "🥎", "🎾", "🏐", "🏉",
        "🥏", "🎱", "🪀", "🏓", "🏸", "🏒", "🥍", "🏏",
        "🥊", "🥋", "🥅", "⛳", "🏹", "🎣", "🤿", "🎽",
        "🛹", "🛼", "🛷", "⛸", "🎯", "🪄", "🪅", "🎮",
        "🚀", "🛸", "🚁", "⛵", "🛶", "🚤", "⚓", "⚡",
        "🌙", "⭐", "🌟", "✨", "💥", "🔥", "🌈", "☀️",
        "💎", "🔔", "🔑", "🗝", "🎸", "🎷", "🎺", "🎻",
        "🥁", "🎹", "🎙", "📻", "🎨", "🎭", "🎬", "🎪",
        "🧭", "⏰", "⏱", "⌛", "💡", "🔦", "🕯", "🪔",
    ]

    public static func generate(sharedSecret: Data) -> String {
        let hash = Array(SHA256.hash(data: sharedSecret))
        return "\(table[Int(hash[0])]) \(table[Int(hash[1])]) \(table[Int(hash[2])]) \(table[Int(hash[3])])"
    }

    public static func deriveCallFingerprint(dhSecretHex: String?, password: String?) -> String? {
        let dhBytes = dhSecretHex.flatMap { Data(hexString: $0) }
        let cleanPwd = password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? password : nil

        switch (dhBytes, cleanPwd) {
        case (.some(let dh), .some(let pwd)):
            var hasher = SHA256()
            hasher.update(data: dh)
            hasher.update(data: Data(":".utf8))
            hasher.update(data: Data(pwd.utf8))
            return generate(sharedSecret: Data(hasher.finalize()))
        case (.some(let dh), .none):
            if dh.count == 32 {
                return generate(sharedSecret: dh)
            }
            return generate(sharedSecret: Data(SHA256.hash(data: dh)))
        case (.none, .some(let pwd)):
            return generate(sharedSecret: Data(SHA256.hash(data: Data(pwd.utf8))))
        case (.none, .none):
            return nil
        }
    }
}
