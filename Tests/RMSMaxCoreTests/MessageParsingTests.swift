// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

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
        XCTAssertEqual(PermissionState.from(.authorized, alertsOn: true, soundOn: true), .granted)
        XCTAssertEqual(PermissionState.from(.authorized, alertsOn: true, soundOn: false), .silenced, "no sound: the user wants to hear messages")
        XCTAssertEqual(PermissionState.from(.authorized, alertsOn: false, soundOn: true), .silenced, "no banner (style «None»): nothing to see")
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

final class MediaCacheManagerTests: XCTestCase {
    private func attach(_ type: String, size: UInt64? = nil, videoType: Int? = nil) -> MaxAttachment {
        var a = MaxAttachment(id: "1", type: type, title: nil, url: nil, fileId: nil, photoId: nil, videoId: 1, width: nil, height: nil,
                              durationMs: nil, mime: nil, size: size)
        a.videoType = videoType
        return a
    }

    func testAutoDownloadRules() {
        var r = MediaAutoDownload()
        XCTAssertTrue(r.shouldDownload(attach("VIDEO", videoType: 1)), "circles are fetched in advance")
        XCTAssertTrue(r.shouldDownload(attach("AUDIO")))
        XCTAssertTrue(r.shouldDownload(attach("PHOTO")))
        XCTAssertTrue(r.shouldDownload(attach("VIDEO", size: 10 * 1_048_576)))
        XCTAssertFalse(r.shouldDownload(attach("VIDEO", size: 80 * 1_048_576)), "over the size limit")
        XCTAssertFalse(r.shouldDownload(attach("VIDEO")), "unknown size is not downloaded blindly")
        XCTAssertFalse(r.shouldDownload(attach("FILE", size: 30 * 1_048_576)))
        r.fileMaxMB = 0
        XCTAssertFalse(r.shouldDownload(attach("FILE", size: 100)))
        XCTAssertTrue(r.shouldDownload(attach("AUDIO"), metered: true), "voice only on a metered network")
        XCTAssertFalse(r.shouldDownload(attach("PHOTO"), metered: true))
        r.onMeteredNetwork = true
        XCTAssertTrue(r.shouldDownload(attach("PHOTO"), metered: true))
    }

    func testKindsAndEvictionOrder() throws {
        XCTAssertEqual(MediaKind.of(key: "video_5"), .video)
        XCTAssertEqual(MediaKind.of(key: "audio_5"), .voice)
        XCTAssertEqual(MediaKind.of(key: "enc_5"), .file)
        XCTAssertEqual(MediaKind.of(key: "img"), .small)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rmscache_\(UUID().uuidString)")
        MediaCache.overrideDirectory = tmp
        defer { MediaCache.overrideDirectory = nil; try? FileManager.default.removeItem(at: tmp) }
        func put(_ key: String, _ name: String, bytes: Int, age: TimeInterval) throws {
            let u = MediaCache.url(key: key, fileName: name)
            try Data(count: bytes).write(to: u)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: u.path)
        }
        try put("video_1", "a.mp4", bytes: 1000, age: 300)   // oldest
        try put("photo_2", "b.jpg", bytes: 1000, age: 200)
        try put("audio_3", "c.caf", bytes: 1000, age: 100)   // newest
        XCTAssertEqual(MediaCache.stats()[.video], 1000)
        MediaCache.enforceLimit(2000)                        // 3000 > 2000 → down to 85 % (1700): the two oldest go
        XCTAssertNil(MediaCache.stats()[.video])
        XCTAssertNil(MediaCache.stats()[.photo])
        XCTAssertEqual(MediaCache.stats()[.voice], 1000, "the most recently used file survives")
        MediaCache.clear(kinds: [.voice])
        XCTAssertTrue(MediaCache.stats().isEmpty)
    }
}

final class TextFormattingTests: XCTestCase {
    func testMarkdownBecomesElements() {
        let r = TextFormatter.parse("Привет **мир** и _курсив_, `код` ~~нет~~ __под__")
        XCTAssertEqual(r.text, "Привет мир и курсив, код нет под")
        let types = r.elements.map(\.type)
        XCTAssertEqual(types, ["STRONG", "EMPHASIZED", "MONOSPACED", "STRIKETHROUGH", "UNDERLINE"])
        XCTAssertEqual(r.elements[0].from, 7); XCTAssertEqual(r.elements[0].length, 3)   // «мир»
        XCTAssertEqual(r.elements[1].from, 13); XCTAssertEqual(r.elements[1].length, 6)  // «курсив»
    }

    func testPositionsAreUTF16Units() {
        let r = TextFormatter.parse("😀 **a**")
        XCTAssertEqual(r.text, "😀 a")
        XCTAssertEqual(r.elements[0].from, 3, "the emoji is two UTF-16 units")
    }

    func testUnmatchedAndWordInternalMarkersStayLiteral() {
        XCTAssertEqual(TextFormatter.parse("snake_case_name и 2*3*4").elements.count, 0)
        XCTAssertEqual(TextFormatter.parse("**не закрыто").text, "**не закрыто")
        XCTAssertTrue(TextFormatter.parse("** **").elements.isEmpty)
    }

    func testLinkQuoteHeadingAndMention() {
        let r = TextFormatter.parse("# Тема\n> цитата\n[сайт](https://example.com) @Иван Петров привет",
                                    mentions: [MentionCandidate(id: 7, name: "Иван Петров")])
        XCTAssertEqual(r.text, "Тема\nцитата\nсайт @Иван Петров привет")
        XCTAssertEqual(r.elements.map(\.type), ["HEADING", "QUOTE", "LINK", "USER_MENTION"])
        XCTAssertEqual(r.elements[2].url, "https://example.com")
        XCTAssertEqual(r.elements[3].entityId, 7)
        XCTAssertEqual(r.elements[3].length, 12)
    }

    func testAttributedRendering() {
        let a = FormattedText.attributed("a жир b", elements: [TextElement(type: "STRONG", from: 2, length: 3)])
        XCTAssertEqual(String(a.characters), "a жир b")
        XCTAssertNotNil(a.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized })
    }
}

final class CallAttachTests: XCTestCase {
    func testCallTextLikeTheOfficialClient() {
        let done = CallAttach(isVideo: true, hangupType: "HUNGUP", durationMs: 83_000, joinLink: nil)
        XCTAssertEqual(done.text(outgoing: true), "Исходящий видеозвонок · 1:23")
        XCTAssertEqual(done.text(outgoing: false), "Входящий видеозвонок · 1:23")
        XCTAssertEqual(CallAttach(isVideo: false, hangupType: "MISSED", durationMs: 0, joinLink: nil).text(outgoing: false), "Пропущенный звонок")
        XCTAssertEqual(CallAttach(isVideo: true, hangupType: "CANCELED", durationMs: 0, joinLink: nil).text(outgoing: true), "Отменённый видеозвонок")
        XCTAssertEqual(CallAttach(isVideo: true, hangupType: "HUNGUP", durationMs: 5000, joinLink: "x").text(outgoing: true), "Звонок по ссылке · 0:05")
    }

    @MainActor func testCallAttachIsParsedFromAMessage() {
        let m = AppStore().parseMessage(.object(["id": .string("5"), "sender": .int(1), "time": .int(1), "attaches": .array([
            .object(["_type": .string("CALL"), "conversationId": .string("c"), "callType": .string("VIDEO"),
                     "hangupType": .string("HUNGUP"), "duration": .int(83000)]),
        ])]), chatId: 3)
        XCTAssertEqual(m.attaches[0].call?.durationMs, 83000)
        XCTAssertEqual(m.attaches[0].call?.isVideo, true)
        XCTAssertEqual(m.displayText, "Видеозвонок · 1:23", "chat-list preview")
    }
}

@MainActor
final class ReactionsTests: XCTestCase {
    private func store(with msg: MaxMessage) -> AppStore {
        let s = AppStore(); s.messagesByChat[1] = [msg]; return s
    }

    func testAdjustReplacesMyReactionAndKeepsCounts() {
        var m = AppStore().parseMessage(.object(["id": .string("9"), "sender": .int(2), "time": .int(1),
            "reactionInfo": .object(["yourReaction": .string("👍"), "counters": .array([
                .object(["reaction": .string("👍"), "count": .int(2)]), .object(["reaction": .string("🔥"), "count": .int(1)])])])]), chatId: 1)
        XCTAssertEqual(m.myReaction, "👍")
        let s = store(with: m)
        s.adjustReaction(chatId: 1, messageId: "9", remove: "👍", add: "❤️")
        m = s.messagesByChat[1]![0]
        XCTAssertEqual(m.myReaction, "❤️")
        XCTAssertEqual(m.reactions.first { $0.reaction == "👍" }?.count, 1)
        XCTAssertEqual(m.reactions.first { $0.reaction == "❤️" }?.count, 1)
        s.adjustReaction(chatId: 1, messageId: "9", remove: "🔥", add: nil)
        XCTAssertNil(s.messagesByChat[1]![0].reactions.first { $0.reaction == "🔥" }, "a count of zero disappears")
    }

    func testAvailableReactionsFollowTheChatSettings() {
        let s = AppStore()
        XCTAssertEqual(s.availableReactions(chatId: 5), AppStore.defaultReactions)
        s.chatReactions[5] = ChatReactions(isActive: false, ids: [])
        XCTAssertTrue(s.availableReactions(chatId: 5).isEmpty, "reactions switched off in this chat")
        s.chatReactions[5] = ChatReactions(isActive: true, ids: ["👍", "🔥", "anim_17"])
        XCTAssertEqual(s.availableReactions(chatId: 5), ["👍", "🔥"], "animated ids are left to the server")
    }
}

@MainActor
final class FormattingWireTests: XCTestCase {
    func testIncomingElementsParsed() {
        let m = AppStore().parseMessage(.object(["id": .string("1"), "sender": .int(2), "time": .int(1), "text": .string("hi bold"),
            "elements": .array([.object(["type": .string("STRONG"), "from": .int(3), "length": .int(4)])])]), chatId: 1)
        XCTAssertEqual(m.elements, [TextElement(type: "STRONG", from: 3, length: 4)])
    }
    func testMentionInOutgoingText() {
        let r = TextFormatter.parse("привет @Иван, **ок**", mentions: [MentionCandidate(id: 7, name: "Иван")])
        XCTAssertEqual(r.text, "привет @Иван, ок")
        XCTAssertTrue(r.elements.contains { $0.type == "USER_MENTION" && $0.entityId == 7 })
        XCTAssertTrue(r.elements.contains { $0.type == "STRONG" })
    }
}

@MainActor
final class AnimojiTests: XCTestCase {
    func testAnimojiElementsMarkTheNextOccurrences() {
        let a = AnimojiSample.make(id: 7, emoji: "😀"), b = AnimojiSample.make(id: 8, emoji: "🔥")
        let els = AppStore.animojiElements(in: "hi 😀 and 🔥 😀", picks: [a, b, a])
        XCTAssertEqual(els.map(\.entityId), [7, 8, 7])
        XCTAssertEqual(els.map(\.from), [3, 10, 13], "UTF-16 offsets")
        XCTAssertTrue(els.allSatisfy { $0.type == "ANIMOJI" && $0.length == 2 })
    }

    func testElementRoundTripKeepsAnimojiAttributes() {
        let e = TextElement(type: "ANIMOJI", from: 0, length: 2, entityId: 5, animojiLottieUrl: "https://x/y.json", animojiSetId: "9")
        XCTAssertEqual(TextElement(e.json), e)
    }

    func testAnimojiAndSetParsing() {
        let a = Animoji.parse(.object(["id": .int(1), "emoji": .string("😀"), "lottieUrl": .string("u"), "iconUrl": .string("i"), "setId": .int(3)]))
        XCTAssertEqual(a?.animationURL, "u")
        let s = AnimojiSet.parse(.object(["id": .int(3), "name": .string("Набор"), "iconUrl": .string("i"), "animojiIds": .array([.int(1), .int(2)])]))
        XCTAssertEqual(s?.animojiIds, [1, 2])
    }
}

enum AnimojiSample {
    static func make(id: Int64, emoji: String) -> Animoji { Animoji.parse(.object(["id": .int(id), "emoji": .string(emoji)]))! }
}

final class RichTextTests: XCTestCase {
    func testElementsRoundTrip() {
        let els = [TextElement(type: "STRONG", from: 0, length: 5), TextElement(type: "EMPHASIZED", from: 3, length: 4),
                   TextElement(type: "LINK", from: 8, length: 3, url: "https://a.b")]
        let s = RichText.attributed("hello world!", elements: els)
        let back = RichText.elements(from: s)
        XCTAssertEqual(Set(back.map { "\($0.type):\($0.from):\($0.length):\($0.url ?? "")" }),
                       Set(els.map { "\($0.type):\($0.from):\($0.length):\($0.url ?? "")" }))
    }

    func testTouchingRunsMergeAndPlainTextHasNone() {
        let s = NSMutableAttributedString(string: "abcdef")
        s.addAttribute(RichFormat.strong.key, value: true, range: NSRange(location: 0, length: 3))
        s.addAttribute(RichFormat.strong.key, value: true, range: NSRange(location: 3, length: 3))
        XCTAssertEqual(RichText.elements(from: s), [TextElement(type: "STRONG", from: 0, length: 6)])
        XCTAssertTrue(RichText.elements(from: NSAttributedString(string: "plain")).isEmpty)
    }

    func testTrimShiftsAndClipsElements() {
        let els = [TextElement(type: "STRONG", from: 0, length: 4), TextElement(type: "EMPHASIZED", from: 5, length: 3)]
        let r = RichText.shifted(els, original: "  abc de \n", trimmed: "abc de")
        XCTAssertEqual(r.map { "\($0.type):\($0.from):\($0.length)" }, ["STRONG:0:2", "EMPHASIZED:3:3"])
    }

    func testTypedMentionBecomesElementOnce() {
        let m = RichText.mentionElements(in: "hi @Иван and @Иван", candidates: [MentionCandidate(id: 7, name: "Иван")], existing: [])
        XCTAssertEqual(m.map(\.from), [3, 13])
    }
}

final class ConferenceLinkTests: XCTestCase {
    func testBareTokenBecomesJoinURL() {
        XCTAssertEqual(AppStore.conferenceURL("c6BsFPvw00bfhRZNWW6N"), "https://max.ru/joincall/c6BsFPvw00bfhRZNWW6N")
        XCTAssertEqual(AppStore.conferenceURL(" https://max.ru/joincall/abc "), "https://max.ru/joincall/abc")
    }
}

final class DeepLinkAndSoundTests: XCTestCase {
    func testDeepLinksFromBothSchemes() {
        XCTAssertEqual(MaxDeepLink.parse(URL(string: "max://max.ru/joincall/abc")!), .joinCall(token: "abc"))
        XCTAssertEqual(MaxDeepLink.parse(URL(string: "https://max.ru/joincall/abc")!), .joinCall(token: "abc"))
        XCTAssertEqual(MaxDeepLink.parse(URL(string: "max://join/HASH")!), .joinChat(hash: "HASH"))
        XCTAssertEqual(MaxDeepLink.parse(URL(string: "https://max.ru/c/-123/456")!), .message(chatId: -123, messageId: "456"))
        XCTAssertNil(MaxDeepLink.parse(URL(string: "https://example.com/join/x")!))
        XCTAssertEqual(MaxDeepLink.joinChat(hash: "H").webURL, "https://max.ru/join/H")
    }

    @MainActor func testEveryToneIsValidAudio() throws {
        for t in [CallSounds.Tone.ringtone, .ringback, .connected, .busy, .ended] {
            let d = CallSounds.wav(for: t)
            XCTAssertEqual(String(data: d.prefix(4), encoding: .ascii), "RIFF")
            XCTAssertGreaterThan(d.count, 5000)
            _ = try AVAudioPlayerProbe.open(d)
        }
    }
}
import AVFoundation
enum AVAudioPlayerProbe { static func open(_ d: Data) throws -> AVAudioPlayer { try AVAudioPlayer(data: d) } }
