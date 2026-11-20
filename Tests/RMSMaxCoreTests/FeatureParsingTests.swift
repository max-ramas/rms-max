// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import XCTest
@testable import RMSMaxCore

final class FeatureParsingTests: XCTestCase {
    func testChatActiveCallFromVideoConversation() {
        let call = AppStore.parseActiveCall(.object([
            "conversationId": .string("c-1"), "joinLink": .string("https://max.ru/call/abc"),
            "startedAt": .int(1700), "approxParticipantsCount": .int(3), "type": .string("VIDEO"),
        ]))
        XCTAssertEqual(call?.joinLink, "https://max.ru/call/abc")
        XCTAssertEqual(call?.participantsCount, 3)
        XCTAssertEqual(call?.isVideo, true)
        XCTAssertNil(AppStore.parseActiveCall(.object(["conversationId": .string("c")])))
        XCTAssertNil(AppStore.parseActiveCall(nil))
    }

    func testCallHistoryItem() {
        let item = CallHistoryItem(.object([
            "historyId": .int(5), "callId": .string("x"), "callerId": .int(42), "chatId": .int(9),
            "callType": .string("VIDEO"), "hangupType": .string("MISSED"), "time": .int(1000), "durationMs": .int(0),
        ]))
        XCTAssertEqual(item?.id, 5)
        XCTAssertEqual(item?.isVideo, true)
        XCTAssertEqual(item?.isMissed, true)
        XCTAssertEqual(item?.isGroup, false)
        XCTAssertNil(CallHistoryItem(.object(["callId": .string("x")])))
    }

    func testTypedChatIds() {
        func chat(_ t: ChatType) -> MaxChat {
            MaxChat(id: 77, type: t, title: "", avatarURL: nil, lastEventTime: 0, newMessages: 0, dontDisturbUntil: 0, participants: [:], lastMessage: nil, pinnedMessageId: nil)
        }
        XCTAssertEqual(AppStore.typedChatId(chat(.dialog)), .object(["type": .int(0), "primaryId": .int(77)]))
        XCTAssertEqual(AppStore.typedChatId(chat(.chat))["type"], .int(1))
        XCTAssertEqual(AppStore.typedChatId(chat(.channel))["type"], .int(2))
    }

    func testSFUVideoQualityFrame() throws {
        var frame = Data([5])
        frame.append(try MsgPack.encode(.array([.int(512_000), .int(640), .int(0)])))
        XCTAssertEqual(SFUNotificationDecoder().decode(frame), [.videoQuality(maxBitrate: 512_000, maxDimension: 640, screen: false)])
    }

    func testHandStateAndCompositeIds() {
        XCTAssertEqual(AppStore.handState(.object(["state": .object(["hand": .string("1")])])), true)
        XCTAssertEqual(AppStore.handState(.object(["state": .object(["hand": .string("0")])])), false)
        XCTAssertNil(AppStore.handState(.object([:])))
        XCTAssertEqual(AppStore.composite(CallParticipantRef(id: 12)), "u12")
        XCTAssertEqual(AppStore.composite(CallParticipantRef(id: 12, deviceIdx: 3)), "u12:d3")
        XCTAssertEqual(AppStore.parseComposite("u12:d3"), CallParticipantRef(id: 12, deviceIdx: 3))
    }

    func testAdminPermissionsAreMobileStrings() {
        // Mobile protocol (op 55 adminParticipants) takes permission names, not the web bitmask.
        XCTAssertEqual(Set(AppStore.adminPermissions),
                       ["CHANGE_CHAT_INFO", "DELETE_OTHERS_MESSAGES", "PIN_MESSAGE", "ADD_REMOVE_MEMBERS", "ADD_ADMINS", "CALL"])
    }

    func testControlEventSummaries() {
        XCTAssertEqual(ControlEvent(event: "hello", userIds: [], title: nil).summary, "Теперь в MAX")
        XCTAssertEqual(ControlEvent(event: "system", userIds: [], title: nil, message: "Текст").summary, "Текст")
        XCTAssertEqual(ControlEvent(event: "privacyWarning", userIds: [], title: nil, kind: "screenshot").summary, "Сделан снимок экрана")
    }
}
