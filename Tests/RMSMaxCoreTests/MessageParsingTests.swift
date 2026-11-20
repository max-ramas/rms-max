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
