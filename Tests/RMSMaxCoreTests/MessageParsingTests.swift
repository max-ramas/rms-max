import XCTest
import AVFoundation
import Contacts
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

final class PermissionStateTests: XCTestCase {
    func testNotificationStateMapping() {
        XCTAssertEqual(PermissionState.from(.notDetermined, alertsOn: false, soundOn: false), .notDetermined)
        XCTAssertEqual(PermissionState.from(.denied, alertsOn: true, soundOn: true), .denied)
        XCTAssertEqual(PermissionState.from(.authorized, alertsOn: true, soundOn: false), .granted)
        XCTAssertEqual(PermissionState.from(.authorized, alertsOn: false, soundOn: true), .granted)
        XCTAssertEqual(PermissionState.from(.authorized, alertsOn: false, soundOn: false), .silenced,
                       "allowed in the system but no banner and no sound: the user would still see nothing")
        XCTAssertFalse(PermissionState.silenced.isUsable)
    }

    func testAVAndContactsMapping() {
        XCTAssertEqual(PermissionState.from(AVAuthorizationStatus.authorized), .granted)
        XCTAssertEqual(PermissionState.from(AVAuthorizationStatus.denied), .denied)
        XCTAssertEqual(PermissionState.from(AVAuthorizationStatus.notDetermined), .notDetermined)
        XCTAssertEqual(PermissionState.from(CNAuthorizationStatus.denied), .denied)
        XCTAssertEqual(PermissionState.from(CNAuthorizationStatus.authorized), .granted)
    }
}

@MainActor
final class ChatMuteConfigTests: XCTestCase {
    func testMuteComesFromAccountConfig() {
        let store = AppStore()
        store.chats = [
            MaxChat(id: 7, type: .dialog, title: "", avatarURL: nil, lastEventTime: 0, newMessages: 0,
                    dontDisturbUntil: 0, participants: [:], lastMessage: nil, pinnedMessageId: nil),
        ]
        store.applyConfigMutes(.object(["chats": .object(["7": .object(["dontDisturbUntil": .int(-1)])])]))
        XCTAssertTrue(store.chats[0].isMuted, "login config carries the mute, the chat object does not")
        store.applyConfigMutes(.object(["chats": .object(["7": .object(["dontDisturbUntil": .int(0)])])]))
        XCTAssertFalse(store.chats[0].isMuted)
    }
}

@MainActor
final class DraftsCommentsCirclesTests: XCTestCase {
    func testDraftsAreKeptPerChatAndEmptyOnesDropped() {
        let store = AppStore()
        UserDefaults.standard.removeObject(forKey: "rmsmaks.drafts.0")
        store.setDraft(chatId: 5, text: "привет")
        store.setDraft(chatId: 6, text: "   ")
        XCTAssertEqual(store.drafts[5], "привет")
        XCTAssertNil(store.drafts[6], "a whitespace-only draft is not a draft")
        let again = AppStore()
        again.loadDrafts()
        XCTAssertEqual(again.drafts[5], "привет", "drafts survive a restart")
        store.setDraft(chatId: 5, text: "")
        XCTAssertNil(store.drafts[5])
        UserDefaults.standard.removeObject(forKey: "rmsmaks.drafts.0")
    }

    func testFailedSendIsKeptAndDiscarded() {
        let store = AppStore()
        struct E: Error {}
        store.recordFailedSend(chatId: 9, text: "не ушло", replyToId: nil, attachment: nil, error: E())
        XCTAssertEqual(store.failedSends[9]?.count, 1)
        XCTAssertEqual(store.failedSends[9]?.first?.preview, "не ушло")
        store.discardFailedSend(store.failedSends[9]![0])
        XCTAssertNil(store.failedSends[9], "no empty arrays left behind")
    }

    func testVideoMessageAndCommentsCountParsing() {
        let store = AppStore()
        let m = store.parseMessage(.object([
            "id": .string("100"), "sender": .int(1), "text": .string("пост"), "time": .int(1),
            "commentsInfo": .object(["totalCount": .int(12)]),
            "attaches": .array([.object(["_type": .string("VIDEO"), "videoId": .int(5), "videoType": .int(1), "duration": .int(4200)])]),
        ]), chatId: 3)
        XCTAssertEqual(m.commentsCount, 12)
        XCTAssertTrue(m.attaches[0].isVideoMessage)
        let plain = store.parseMessage(.object(["id": .string("101"), "sender": .int(1), "time": .int(1),
                                                "attaches": .array([.object(["_type": .string("VIDEO"), "videoId": .int(6)])])]), chatId: 3)
        XCTAssertNil(plain.commentsCount)
        XCTAssertFalse(plain.attaches[0].isVideoMessage)
        XCTAssertEqual(AppStore.commentsWord(1), "комментарий")
        XCTAssertEqual(AppStore.commentsWord(3), "комментария")
        XCTAssertEqual(AppStore.commentsWord(12), "комментариев")
        XCTAssertEqual(AppStore.commentsWord(21), "комментарий")
    }
}

@MainActor
final class MuteCacheTests: XCTestCase {
    func testMuteSurvivesALoginWithoutConfig() {
        let store = AppStore()
        UserDefaults.standard.removeObject(forKey: "rmsmaks.mutes.0")
        store.chats = [MaxChat(id: 4, type: .chat, title: "", avatarURL: nil, lastEventTime: 0, newMessages: 0,
                               dontDisturbUntil: 0, participants: [:], lastMessage: nil, pinnedMessageId: nil)]
        store.applyConfigMutes(.object(["chats": .object(["4": .object(["dontDisturbUntil": .int(-1)])])]))
        // a later login answer has no config at all: chats are re-parsed with 0
        store.chats[0].dontDisturbUntil = 0
        store.applyConfigMutes(nil)
        store.applyStoredMutes()
        XCTAssertTrue(store.chats[0].isMuted)
        UserDefaults.standard.removeObject(forKey: "rmsmaks.mutes.0")
    }

    func testKnownRejectedOpcodeIsNeverSent() {
        XCTAssertTrue(UnsupportedOpcodes.contains(241))
    }
}

final class VideoFileCheckTests: XCTestCase {
    func testOnlyRealVideoContainersPass() {
        var mp4 = Data(count: 4); mp4.append(Data("ftypisom".utf8)); mp4.append(Data(count: 20))
        XCTAssertTrue(MediaHTTP.looksLikeVideo(mp4))
        XCTAssertTrue(MediaHTTP.looksLikeVideo(Data([0, 0, 0, 0x20] + Array("ftypmp42".utf8) + [0, 0, 0, 0, 0])))
        XCTAssertFalse(MediaHTTP.looksLikeVideo(Data("<!DOCTYPE html><html>".utf8) + Data(count: 30)), "a web page is not a video")
        XCTAssertFalse(MediaHTTP.looksLikeVideo(Data("10".utf8)), "the CDN's error body")
    }
}
