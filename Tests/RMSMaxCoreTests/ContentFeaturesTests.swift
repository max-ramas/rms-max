import XCTest
@testable import RMSMaxCore

@MainActor
final class ContentFeaturesTests: XCTestCase {
    func testStickerParse() {
        let s = AppStore.parseSticker(.object([
            "id": .int(9), "url": .string("https://x/a.webp"), "previewUrl": .string("https://x/p.webp"),
            "width": .int(512), "height": .int(512), "type": .string("LOTTIE"), "lottieUrl": .string("https://x/a.json"),
        ]))
        XCTAssertEqual(s?.id, 9)
        XCTAssertEqual(s?.displayURL, "https://x/p.webp", "lottie stickers render their static preview")
        XCTAssertEqual(AppStore.parseSticker(.object(["id": .int(1), "url": .string("u"), "type": .string("STATIC")]))?.displayURL, "u")
        XCTAssertNil(AppStore.parseSticker(.object(["id": .int(1)])))
    }

    func testPollParseAndState() {
        var poll = MaxPoll.parse(.object([
            "_type": .string("POLL"), "pollId": .int(77), "title": .string("Где встречаемся?"), "settings": .int(2 | 4),
            "answers": .array([
                .object(["text": .string("Дома"), "answerId": .int(0)]),
                .object(["text": .string("В кафе"), "answerId": .int(1)]),
            ]),
            "state": .object(["total": .int(3), "result": .array([
                .object(["answerId": .int(0), "voteCount": .int(1), "rate": .int(33), "options": .int(0)]),
                .object(["answerId": .int(1), "voteCount": .int(2), "rate": .int(67), "options": .int(1)]),
            ])]),
        ]))
        XCTAssertEqual(poll?.isMultiple, true)
        XCTAssertEqual(poll?.canRevote, true)
        XCTAssertEqual(poll?.isAnonymous, false)
        XCTAssertEqual(poll?.total, 3)
        XCTAssertEqual(poll?.answers[1].percent, 67)
        XCTAssertEqual(poll?.hasVoted, true)
        poll?.apply(state: .object(["total": .int(4), "result": .array([.object(["answerId": .int(0), "voteCount": .int(2), "rate": .int(50), "options": .int(1)])])]))
        XCTAssertEqual(poll?.answers[0].votedByMe, true)
        XCTAssertEqual(poll?.total, 4)
    }

    func testBotKeyboardParse() {
        let kb = BotKeyboard.parse(.object([
            "_type": .string("INLINE_KEYBOARD"), "callbackId": .string("cb1"),
            "keyboard": .object(["buttons": .array([
                .array([.object(["type": .string("CALLBACK"), "text": .string("Да"), "payload": .string("yes")]),
                        .object(["type": .string("LINK"), "text": .string("Сайт"), "url": .string("https://example.org")])]),
                .array([.object(["type": .string("OPEN_APP"), "text": .string("App")])]),
            ])]),
        ]))
        XCTAssertEqual(kb?.callbackId, "cb1")
        XCTAssertEqual(kb?.rows.count, 2)
        XCTAssertEqual(kb?.rows[0][0].payload, "yes")
        XCTAssertEqual(kb?.rows[0][1].url, "https://example.org")
    }

    func testFolderMembership() {
        let store = AppStore()
        func chat(_ id: Int64, _ t: ChatType, unread: Int = 0) -> MaxChat {
            MaxChat(id: id, type: t, title: "c\(id)", avatarURL: nil, lastEventTime: 0, newMessages: unread, dontDisturbUntil: 0, participants: [:], lastMessage: nil, pinnedMessageId: nil)
        }
        store.chats = [chat(1, .chat), chat(2, .dialog, unread: 3), chat(3, .channel), chat(4, .chat, unread: 1)]
        let groupsUnread = ChatFolder(id: "f", title: "F", include: [3], exclude: [4], filters: [ChatFolder.Filter.chat.rawValue, ChatFolder.Filter.unread.rawValue])
        XCTAssertEqual(Set(store.chats(in: groupsUnread).map(\.id)), [1, 2, 3])
        XCTAssertEqual(store.chats(in: ChatFolder(id: "e", title: "E")).count, 0)
    }

    func testStoryOwner() {
        XCTAssertEqual(AppStore.storyOwner(.object(["type": .int(2), "ownerId": .int(55)])), StoryOwner(type: 2, id: 55))
        XCTAssertNil(AppStore.storyOwner(.object([:])))
    }
}
