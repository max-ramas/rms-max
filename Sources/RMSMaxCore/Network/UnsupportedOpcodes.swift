import Foundation

/// Opcodes the MAX server answered with `proto.opcode` (unknown command). The mobile endpoint closes the socket
/// right after that error, so such commands must never be sent again — remembered across launches, per app version
/// (a newer build may use them correctly again).
public enum UnsupportedOpcodes {
    private static let key = "rmsmaks.unsupportedOpcodes2." + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
    private static let lock = NSLock()
    private static var cache: Set<UInt16> = {
        Set((UserDefaults.standard.array(forKey: key) as? [Int] ?? []).map { UInt16(clamping: $0) })
    }()

    public static func contains(_ op: UInt16) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cache.contains(op)
    }

    static func insert(_ op: UInt16) {
        lock.lock(); defer { lock.unlock() }
        guard cache.insert(op).inserted else { return }
        UserDefaults.standard.set(cache.map(Int.init).sorted(), forKey: key)
        ProtocolLog.add("op=\(op) marked unsupported; will not be sent again")
    }

    public static var all: [UInt16] {
        lock.lock(); defer { lock.unlock() }
        return cache.sorted()
    }
}
