import XCTest
@testable import RMSMaxCore

@MainActor
final class MessageParsingTests: XCTestCase {
    func testForwardTakesTextAndAttachesFromLinkedMessage() {
        let store = AppStore()
        let raw: JSONValue = .object([
            "id": .string("10"), "sender": .int(1), "text": .string(""), "time": .int(1000),
            "link": .object([
                "type": .string("FORWARD"), "chatId": .int(55),
                "message": .object([
                    "sender": .int(77), "text": .string("https://youtube.com/shorts/abcDEF12345"),
                    "attaches": .array([.object(["_type": .string("SHARE"), "shareId": .int(5), "url": .string("https://youtube.com/shorts/abcDEF12345"),
                                                 "title": .string("Ролик"), "image": .object(["baseUrl": .string("https://i.oneme.ru/x")])])]),
                ]),
            ]),
        ])
        let m = store.parseMessage(raw, chatId: 1)
        XCTAssertEqual(m.text, "https://youtube.com/shorts/abcDEF12345")
        XCTAssertEqual(m.forwardedFromId, 77)
        XCTAssertNil(m.replyToMessageId)
        XCTAssertEqual(m.attaches.first?.share?.title, "Ролик")
        XCTAssertEqual(m.attaches.first?.share?.imageURL, "https://i.oneme.ru/x")
    }

    func testControlContactLocationAttaches() {
        let atts = AppStore.parseAttaches(.array([
            .object(["_type": .string("CONTROL"), "event": .string("add"), "userIds": .array([.int(3), .int(4)])]),
            .object(["_type": .string("CONTACT"), "contactId": .int(9)]),
            .object(["_type": .string("LOCATION"), "latitude": .double(55.75), "longitude": .double(37.61)]),
        ]), messageId: "1")
        XCTAssertEqual(atts[0].control?.event, "add")
        XCTAssertEqual(atts[0].control?.userIds, [3, 4])
        XCTAssertEqual(atts[1].contactId, 9)
        XCTAssertEqual(atts[2].latitude, 55.75)
    }

    func testPresenceParsing() {
        let p = ContactPresence(.object(["status": .int(1), "seen": .int(1_700_000_000)]))
        XCTAssertEqual(p?.isOnline, true)
        XCTAssertEqual(p?.label, "в сети")
        let off = ContactPresence(.object(["status": .int(0), "seen": .int(1_700_000_000)]))
        XCTAssertEqual(off?.isOnline, false)
        XCTAssertNotNil(off?.seen)
    }
}

@MainActor
final class ContactNameTests: XCTestCase {
    func testCustomNameWinsAndLastNameIncluded() {
        let store = AppStore()
        let c = store.parseContactValue(.object(["id": .int(5), "names": .array([
            .object(["type": .string("ONEME"), "name": .string("Иван"), "firstName": .string("Иван"), "lastName": .string("Петров")]),
            .object(["type": .string("CUSTOM"), "firstName": .string("Ваня"), "lastName": .string("Работа")]),
        ])]))
        XCTAssertEqual(c.name, "Ваня Работа")
        XCTAssertEqual(c.profileName, "Иван Петров")
        let plain = store.parseContactValue(.object(["id": .int(6), "names": .array([
            .object(["type": .string("ONEME"), "name": .string("Мария"), "firstName": .string("Мария"), "lastName": .string("Иванова")]),
        ])]))
        XCTAssertEqual(plain.name, "Мария Иванова")
        XCTAssertNil(plain.profileName)
    }
}

final class SessionRevokedTests: XCTestCase {
    func testLoginTokenErrorStopsReconnects() {
        XCTAssertTrue(AppStore.isSessionRevoked(MaxTransportError.apiError(.object(["error": .string("login.token")]))))
        XCTAssertFalse(AppStore.isSessionRevoked(MaxTransportError.apiError(.object(["error": .string("proto.state")]))))
        XCTAssertFalse(AppStore.isSessionRevoked(MaxTransportError.requestTimeout))
    }
}

final class DesktopIdentityTests: XCTestCase {
    func testDesktopUserAgentMatchesOfficialClient() {
        let id = MaxIdentity.generateDesktop()
        XCTAssertTrue(id.isDesktop)
        XCTAssertEqual(id.userAgent.deviceType, "DESKTOP")
        XCTAssertEqual(id.userAgent.appVersion, "26.41.1")
        XCTAssertEqual(id.userAgent.buildNumber, 83827)
        let ua = id.userAgent.toJSONValue()
        XCTAssertNil(ua["screen"], "desktop sends no screen")
        XCTAssertNil(ua["pushDeviceType"])
        XCTAssertNotNil(ua["timezone"])
        XCTAssertFalse(MaxIdentity.generateMobile().isDesktop)
    }
}

@MainActor
final class TypingAndReadTests: XCTestCase {
    private func dialog(_ id: Int64, me: Int64, peer: Int64) -> MaxChat {
        MaxChat(id: id, type: .dialog, title: "", avatarURL: nil, lastEventTime: 0, newMessages: 3,
                dontDisturbUntil: 0, participants: [me: 0, peer: 0], lastMessage: nil, pinnedMessageId: nil)
    }

    func testTypingPushShowsAndKinds() {
        let store = AppStore()
        store.chats = [dialog(10, me: 1, peer: 2)]
        XCTAssertNil(store.typingText(chatId: 10))
        store.applyTypingPush(.object(["chatId": .int(10), "userId": .int(2), "type": .string("TEXT")]))
        XCTAssertEqual(store.typingText(chatId: 10), "печатает…")
        store.applyTypingPush(.object(["chatId": .int(10), "userId": .int(2), "type": .string("AUDIO")]))
        XCTAssertEqual(store.typingText(chatId: 10), "записывает голосовое…")
    }

    func testReadMarkOfPeerOnlyMovesForward() {
        let store = AppStore()
        store.chats = [dialog(10, me: 1, peer: 2)]
        let chat = { store.chats[0] }
        store.applyReadMarkPush(.object(["chatId": .int(10), "userId": .int(2), "mark": .int(5000)]))
        XCTAssertEqual(chat().participants[2], 5000)
        store.applyReadMarkPush(.object(["chatId": .int(10), "userId": .int(2), "mark": .int(4000)]))
        XCTAssertEqual(chat().participants[2], 5000)
        XCTAssertEqual(chat().newMessages, 3, "the peer's mark must not clear my unread counter")
    }
}

@MainActor
final class PinsAndFoldersTests: XCTestCase {
    private func chat(_ id: Int64) -> MaxChat {
        MaxChat(id: id, type: .dialog, title: "", avatarURL: nil, lastEventTime: id, newMessages: 0,
                dontDisturbUntil: 0, participants: [:], lastMessage: nil, pinnedMessageId: nil)
    }

    func testFavoritesAreParsedAndPinnedGoFirst() {
        let store = AppStore()
        store.applyFolders(.object(["folders": .array([
            .object(["id": .string("all.chat.folder"), "title": .string("Все"), "favorites": .array([.int(3), .int(1)])]),
            .object(["id": .string("f1"), "title": .string("Работа"), "include": .array([.int(2)]), "favorites": .array([.int(2)])]),
        ])]))
        XCTAssertEqual(store.serverAllFolder?.favorites, [3, 1])
        XCTAssertEqual(store.folders.map(\.id), ["f1"], "the server «all» folder stays out of the tab bar")
        XCTAssertEqual(store.folders.first?.favorites, [2])
        let ordered = store.withPinnedFirst([chat(5), chat(1), chat(3), chat(2)])
        XCTAssertEqual(ordered.map(\.id), [3, 1, 5, 2], "pinned first in pin order, then the rest")
        XCTAssertTrue(store.isChatPinned(3))
        XCTAssertFalse(store.isChatPinned(5))
    }

    func testPinnedStatePushKeepsCount() {
        let store = AppStore()
        store.chats = [chat(10)]
        store.applyPinnedState(.object(["chatId": .object(["type": .int(0), "primaryId": .int(10)]),
                                        "totalPinnedMessagesCount": .int(0)]))
        XCTAssertNil(store.chats[0].pinnedMessageId)
        XCTAssertEqual(store.chats[0].pinnedCount, 0)
    }
}

final class UploadKindTests: XCTestCase {
    func testUploadKindFollowsPathLikeOfficialClient() {
        XCTAssertTrue(MediaHTTP.isMaxMediaUpload(URL(string: "https://au2.oneme.ru/uploadAudio?sig=1")!))
        XCTAssertTrue(MediaHTTP.isMaxMediaUpload(URL(string: "https://x.oneme.ru/uploadImage")!))
        XCTAssertTrue(MediaHTTP.isMaxMediaUpload(URL(string: "https://x.oneme.ru/uploadVideo")!))
        XCTAssertFalse(MediaHTTP.isMaxMediaUpload(URL(string: "https://x.oneme.ru/uploadAudio/extra")!))
        XCTAssertFalse(MediaHTTP.isMaxMediaUpload(URL(string: "https://x.oneme.ru/upload.do")!))
    }

    func testFileNameEncodingMatchesEncodeURIComponent() {
        XCTAssertEqual(MediaHTTP.encodeFileName("voice.ogg"), "voice.ogg")
        XCTAssertEqual(MediaHTTP.encodeFileName("Мой файл (1).pdf"), "%D0%9C%D0%BE%D0%B9%20%D1%84%D0%B0%D0%B9%D0%BB%20(1).pdf")
    }
}
