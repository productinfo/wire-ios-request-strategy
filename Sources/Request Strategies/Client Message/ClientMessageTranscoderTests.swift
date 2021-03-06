//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import Foundation
import WireRequestStrategy
import WireRequestStrategy
import XCTest

class ClientMessageTranscoderTests: MessagingTestBase {

    var localNotificationDispatcher: MockPushMessageHandler!
    var sut: ClientMessageTranscoder!
    var mockApplicationStatus : MockApplicationStatus!
    
    override func setUp() {
        super.setUp()
        self.localNotificationDispatcher = MockPushMessageHandler()
        mockApplicationStatus = MockApplicationStatus()
        mockApplicationStatus.mockSynchronizationState = .eventProcessing
        sut = ClientMessageTranscoder(in: syncMOC, localNotificationDispatcher: localNotificationDispatcher, applicationStatus: mockApplicationStatus)
    }
    
    override func tearDown() {
        self.localNotificationDispatcher = nil
        self.mockApplicationStatus = nil
        self.sut = nil
        
        super.tearDown()
    }
    
    /// Makes a conversation secure
    func set(conversation: ZMConversation, securityLevel: ZMConversationSecurityLevel) {
        conversation.setValue(NSNumber(value: securityLevel.rawValue), forKey: #keyPath(ZMConversation.securityLevel))
        if conversation.securityLevel != securityLevel {
            fatalError()
        }
    }
}


// MARK: - Processing events

extension ClientMessageTranscoderTests {

    func testThatANewOtrMessageIsCreatedFromAnEvent() {
        self.syncMOC.performGroupedBlockAndWait {
            
            // GIVEN
            let text = "Everything"
            let base64Text = "CiQ5ZTU2NTQwOS0xODZiLTRlN2YtYTE4NC05NzE4MGE0MDAwMDQSDAoKRXZlcnl0aGluZw=="
            let payload = [
                "recipient": self.selfClient.remoteIdentifier,
                "sender": self.otherClient.remoteIdentifier,
                "text": base64Text
            ]
            let eventPayload = [
                "type": "conversation.otr-message-add",
                "data": payload,
                "conversation": self.groupConversation.remoteIdentifier!.transportString(),
                "time": Date().transportString()
                ] as NSDictionary
            guard let event = ZMUpdateEvent.decryptedUpdateEvent(fromEventStreamPayload: eventPayload, uuid: nil, transient: false, source: .webSocket) else {
                XCTFail()
                return
            }
            
            // WHEN
            self.sut.processEvents([event], liveEvents: false, prefetchResult: nil)
            
            // THEN
            XCTAssertEqual(self.groupConversation.recentMessages.last?.textMessageData?.messageText, text)
        }
    }
    
    func testThatANewOtrMessageIsCreatedFromADecryptedAPNSEvent() {
        self.syncMOC.performGroupedBlockAndWait {
            
            // GIVEN
            let text = "Everything"
            let event = self.decryptedUpdateEventFromOtherClient(text: text)
            
            // WHEN
            self.sut.processEvents([event], liveEvents: false, prefetchResult: nil)
            
            // THEN
            XCTAssertEqual((self.groupConversation.recentMessages.last as? ZMClientMessage)?.textMessageData?.messageText, text)
        }
    }
    
}

// MARK: - Request generation

extension ClientMessageTranscoderTests {
    
    func testThatItDoesNotGenerateARequestIfSenderIsNotSelfUser() {
        
        self.syncMOC.performGroupedBlockAndWait {
            
            // GIVEN
            let text = "Lorem ipsum"
            let message = self.groupConversation.append(text: text) as! ZMClientMessage
            message.sender = self.otherUser
            self.syncMOC.saveOrRollback()
            
            // WHEN
            self.sut.contextChangeTrackers.forEach { $0.objectsDidChange(Set([message])) }
            
            // THEN
            XCTAssertNil(self.sut.nextRequest())
        }
    }
    
    func testThatItUpdatesExpectsReadConfirmationFlagWhenSendingMessageInOneToOne() {
        self.syncMOC.performGroupedBlockAndWait {
            
            // GIVEN
            ZMUser.selfUser(in: self.syncMOC).readReceiptsEnabled = true
            let text = "Lorem ipsum"
            let message = self.oneToOneConversation.append(text: text) as! ZMClientMessage
            self.syncMOC.saveOrRollback()
            
            // WHEN
            self.sut.contextChangeTrackers.forEach { $0.objectsDidChange(Set([message])) }
            if self.sut.nextRequest() == nil {
                XCTFail()
                return
            }
            
            // THEN
            XCTAssertTrue(message.genericMessage!.content!.expectsReadConfirmation())
        }
    }
    
    func testThatItDoesntUpdateExpectsReadConfirmationFlagWhenSendingMessageInGroup() {
        self.syncMOC.performGroupedBlockAndWait {
            
            // GIVEN
            ZMUser.selfUser(in: self.syncMOC).readReceiptsEnabled = true
            let text = "Lorem ipsum"
            let message = self.groupConversation.append(text: text) as! ZMClientMessage
            self.syncMOC.saveOrRollback()
            
            // WHEN
            self.sut.contextChangeTrackers.forEach { $0.objectsDidChange(Set([message])) }
            if self.sut.nextRequest() == nil {
                XCTFail()
                return
            }
            
            // THEN
            XCTAssertFalse(message.genericMessage!.content!.expectsReadConfirmation())
        }
    }
    
    func testThatItUpdateExpectsReadConfirmationFlagWhenReadReceiptsAreDisabled() {
        self.syncMOC.performGroupedBlockAndWait {
            
            // GIVEN
            ZMUser.selfUser(in: self.syncMOC).readReceiptsEnabled = false
            let text = "Lorem ipsum"
            let message = self.oneToOneConversation.append(text: text) as! ZMClientMessage
            message.add(message.genericMessage!.setExpectsReadConfirmation(true)!.data())
            self.syncMOC.saveOrRollback()
            
            // WHEN
            self.sut.contextChangeTrackers.forEach { $0.objectsDidChange(Set([message])) }
            if self.sut.nextRequest() == nil {
                XCTFail()
                return
            }
            
            // THEN
            XCTAssertFalse(message.genericMessage!.content!.expectsReadConfirmation())
        }
    }
    
    func testThatItGeneratesARequestToSendAClientMessage() {
        self.syncMOC.performGroupedBlockAndWait {
            
            // GIVEN
            let text = "Lorem ipsum"
            let message = self.groupConversation.append(text: text) as! ZMClientMessage
            self.syncMOC.saveOrRollback()
            
            // WHEN
            self.sut.contextChangeTrackers.forEach { $0.objectsDidChange(Set([message])) }
            guard let request = self.sut.nextRequest() else {
                XCTFail()
                return
            }
            
            // THEN
            XCTAssertEqual(request.path, "/conversations/\(self.groupConversation.remoteIdentifier!.transportString())/otr/messages")
            XCTAssertEqual(request.method, .methodPOST)
            XCTAssertNotNil(request.binaryData)
            XCTAssertEqual(request.binaryDataType, "application/x-protobuf")
            
            guard let receivedMessage = self.outgoingEncryptedMessage(from: request, for: self.otherClient) else {
                return XCTFail("Invalid message")
            }
            XCTAssertEqual(receivedMessage.textData?.content, text)
        }
    }
    
    func testThatItGeneratesARequestToSendAClientMessageExternalWithExternalBlob() {
        self.syncMOC.performGroupedBlockAndWait {
            
            // GIVEN
            let text = String(repeating: "Hi", count: 100000)
            let message = self.groupConversation.append(text: text) as! ZMClientMessage
            self.syncMOC.saveOrRollback()
            
            // WHEN
            self.sut.contextChangeTrackers.forEach { $0.objectsDidChange(Set([message])) }
            guard let request = self.sut.nextRequest() else {
                XCTFail()
                return
            }
            
            // THEN
            XCTAssertEqual(request.path, "/conversations/\(self.groupConversation.remoteIdentifier!.transportString())/otr/messages")
            XCTAssertEqual(request.method, .methodPOST)
            XCTAssertNotNil(request.binaryData)
            XCTAssertEqual(request.binaryDataType, "application/x-protobuf")
            
            guard let receivedMessage = self.outgoingEncryptedMessage(from: request, for: self.otherClient) else {
                return XCTFail("Invalid message")
            }
            XCTAssertTrue(receivedMessage.hasExternal())
            guard let key = receivedMessage.external.otrKey,
                let sha = receivedMessage.external.sha256 else { return XCTFail("No external key/sha") }
            
            guard let protobuf = self.outgoingMessageWrapper(from: request) else {
                return XCTFail()
            }
            XCTAssertTrue(protobuf.hasBlob())
            guard let blob = protobuf.blob else { return XCTFail("No blob") }
            XCTAssertEqual(blob.zmSHA256Digest(), sha)
            guard let decryptedBlob = blob.zmDecryptPrefixedPlainTextIV(key: key) else { return XCTFail("Failed to decrypt blob") }
            let externalMessage = ZMGenericMessage.parse(from: decryptedBlob)
            XCTAssertTrue(externalMessage?.textData?.content == text) // here I use == instead of XCTAssertEqual because the 
                // warning generated by a failed comparison of a 200000-chars string almost freezes XCode
        }
    }
}
