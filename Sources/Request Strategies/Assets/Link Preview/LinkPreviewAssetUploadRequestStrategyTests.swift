//
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
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
import WireLinkPreview
import WireDataModel
import WireRequestStrategy
import XCTest

// MARK: - Tests setup
class LinkPreviewAssetUploadRequestStrategyTests: MessagingTestBase {
    
    fileprivate var sut: LinkPreviewAssetUploadRequestStrategy!
    fileprivate var mockApplicationStatus: MockApplicationStatus!
    
    override func setUp() {
        super.setUp()
        
        mockApplicationStatus = MockApplicationStatus()
        mockApplicationStatus.mockSynchronizationState = .eventProcessing

        self.sut = LinkPreviewAssetUploadRequestStrategy(managedObjectContext: self.syncMOC, applicationStatus: mockApplicationStatus, linkPreviewPreprocessor: nil, previewImagePreprocessor: nil)
    }
    
    override func tearDown() {
        mockApplicationStatus = nil
        sut = nil
        super.tearDown()
    }
    
    /// Creates a message that should generate request
    func createMessage(_ text: String, linkPreviewState: ZMLinkPreviewState = .waitingToBeProcessed, linkPreview: LinkPreview, isEphemeral: Bool = false) -> ZMClientMessage {
        let conversation = ZMConversation.insertNewObject(in: self.syncMOC)
        conversation.remoteIdentifier = UUID.create()
        if isEphemeral {
            conversation.messageDestructionTimeout = 10
        }
        let message = conversation.appendMessage(withText: text) as! ZMClientMessage
        message.linkPreviewState = linkPreviewState
        if isEphemeral {
            XCTAssertTrue(message.isEphemeral)
            message.add(ZMGenericMessage.message(text: text, linkPreview: linkPreview.protocolBuffer, nonce: message.nonce!, expiresAfter: NSNumber(value:10)).data())
        } else {
            message.add(ZMGenericMessage.message(text: text, linkPreview: linkPreview.protocolBuffer, nonce: message.nonce!).data())
        }
        self.syncMOC.saveOrRollback()
        
        return message
    }
    
    func createArticle() -> Article {
        let article = Article(
            originalURLString: "example.com/article",
            permanentURLString: "https://example.com/permament",
            resolvedURLString: "https://example.com/permament",
            offset: 0
        )
        article.title = "title"
        article.summary = "summary"
        article.imageData = [mediumJPEGData()]
        
        return article
    }
    
    /// Forces the strategy to process the message
    func process(_ strategy: LinkPreviewAssetUploadRequestStrategy, message: ZMClientMessage) {
        strategy.contextChangeTrackers.forEach {
            $0.objectsDidChange([message])
        }
    }
    
    func completeRequest(_ request: ZMTransportRequest?, HTTPStatus: Int) {
        request?.complete(with: ZMTransportResponse(payload: [] as ZMTransportData, httpStatus: HTTPStatus, transportSessionError: nil))
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
    }
    
    func encryptLinkPreview(inMessage message: ZMClientMessage) -> (Data, Data) {
        let otrKey = "1".data(using: String.Encoding.utf8, allowLossyConversion: false)!
        let sha256 = "2".data(using: String.Encoding.utf8, allowLossyConversion: false)!
        
        var linkPreview = message.genericMessage!.linkPreviews.first!
        linkPreview = linkPreview.update(withOtrKey: otrKey, sha256: sha256)
        
        message.add(ZMGenericMessage.message(text: (message.textMessageData?.messageText)!, linkPreview: linkPreview, nonce: message.nonce!, expiresAfter: NSNumber(value:message.deletionTimeout)).data())
        
        return (otrKey, sha256)
    }
    
    func completeRequest(_ message: ZMClientMessage, request: ZMTransportRequest?, assetId: String, token: String) {
        let response = ZMTransportResponse(payload: ["key" : assetId, "token": token] as ZMTransportData, httpStatus: 201, transportSessionError: nil)
        _ = sut.updateUpdatedObject(message, requestUserInfo: nil, response: response, keysToParse: [ZMClientMessageLinkPreviewStateKey])
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
    }
}

// MARK: - Tests
extension LinkPreviewAssetUploadRequestStrategyTests {
    
    func testThatItCreatesRequestForProcessedLinkPreview() {
        // GIVEN
        let article = createArticle()
        let message = createMessage(article.permanentURL!.absoluteString, linkPreviewState: .processed, linkPreview: article)
        syncMOC.zm_fileAssetCache.storeAssetData(message, format: .medium, encrypted: true, data: article.imageData.first!)
        
        syncMOC.saveOrRollback()
        process(sut, message: message)
        
        // WHEN
        let request = sut.nextRequest()
        
        // THEN
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.path, "/assets/v3")
        XCTAssertEqual(request?.method, ZMTransportRequestMethod.methodPOST)
    }
    
    func testThatItDoesntCreateUnauthenticatedRequests() {
        // GIVEN
        let article = createArticle()
        let message = createMessage(article.permanentURL!.absoluteString, linkPreviewState: .processed, linkPreview: article)
        self.syncMOC.zm_fileAssetCache.storeAssetData(message, format: .medium, encrypted: true, data: article.imageData.first!)
        process(sut, message: message)
        mockApplicationStatus.mockSynchronizationState = .unauthenticated
        
        // WHEN
        let request = sut.nextRequest()
        
        // THEN
        XCTAssertNil(request)
    }
    
    func testThatItDoesntCreateRequestsForUnprocessedLinkPreview() {
        // GIVEN
        let article = createArticle()
        let message = createMessage(article.permanentURL!.absoluteString, linkPreviewState: .waitingToBeProcessed, linkPreview: article)
        self.syncMOC.zm_fileAssetCache.storeAssetData(message, format: .medium, encrypted: true, data: article.imageData.first!)
        process(sut, message: message)
        
        // WHEN
        let request = sut.nextRequest()
        
        // THEN
        XCTAssertNil(request)
    }
    
    func testThatItDoesntCreateRequestsForLinkPreviewStateDone() {
        // GIVEN
        let article = createArticle()
        let message = createMessage(article.permanentURL!.absoluteString, linkPreviewState: .done, linkPreview: article)
        self.syncMOC.zm_fileAssetCache.storeAssetData(message, format: .medium, encrypted: true, data: article.imageData.first!)
        process(sut, message: message)
        
        // WHEN
        let request = sut.nextRequest()
        
        // THEN
        XCTAssertNil(request)
    }
    
    func testThatItDoesNotCreateARequestIfThereIsNoImageInTheCache() {
        // GIVEN
        let article = createArticle()
        let message = createMessage(article.permanentURL!.absoluteString, linkPreviewState: .processed, linkPreview: article)
        process(sut, message: message)
        
        // WHEN & then
        XCTAssertNil(sut.nextRequest())
    }
    
    func testThatItUpdatesMessageWithAssetKeyAndToken() {
        // GIVEN
        let article = createArticle()
        let message = createMessage(article.permanentURL!.absoluteString, linkPreviewState: .processed, linkPreview: article)
        let (otrKey, sha256) = encryptLinkPreview(inMessage: message);
        
        syncMOC.zm_fileAssetCache.storeAssetData(message, format: .medium, encrypted: true, data: article.imageData.first!)
        _ = encryptLinkPreview(inMessage: message)
        message.linkPreviewState = .waitingToBeProcessed
        syncMOC.saveOrRollback()
        
        process(sut, message: message)
        let request = sut.nextRequest()
        
        let assetId = "id123"
        let token = "qJ8JPFLsiYGx7fnrlL+7Yk9="
        
        // WHEN
        completeRequest(message, request: request, assetId: assetId, token: token)
        
        // THEN
        let linkPreviews = message.genericMessage!.linkPreviews
        let articleProtocol: ZMArticle = linkPreviews.first!.article
        XCTAssertEqual(articleProtocol.image.uploaded.otrKey, otrKey)
        XCTAssertEqual(articleProtocol.image.uploaded.sha256, sha256)
        XCTAssertEqual(articleProtocol.image.uploaded.assetId, assetId)
        XCTAssertEqual(articleProtocol.image.uploaded.assetToken, token)
    }
    
    func testThatItUpdatesTheLinkPreviewState() {
        // GIVEN
        let article = createArticle()
        let message = createMessage(article.permanentURL!.absoluteString, linkPreviewState: .processed, linkPreview: article)
        _ = encryptLinkPreview(inMessage: message)
        syncMOC.zm_fileAssetCache.storeAssetData(message, format: .medium, encrypted: true, data: article.imageData.first!)
        message.linkPreviewState = .processed
        syncMOC.saveOrRollback()
        
        process(sut, message: message)
        let request = sut.nextRequest()
        
        let assetId = "id123"
        let token = "qJ8JPFLsiYGx7fnrlL+7Yk9="

        // WHEN
        completeRequest(message, request: request, assetId: assetId, token: token)
        
        // THEN
        XCTAssertEqual(message.linkPreviewState, ZMLinkPreviewState.uploaded)
    }
    
}



extension LinkPreviewAssetUploadRequestStrategyTests {
    
    func testThatItUpdatesEphemeralMessageWithAssetKeyAndToken() {
        // GIVEN
        let article = createArticle()
        let message = createMessage(article.permanentURL!.absoluteString, linkPreviewState: .processed, linkPreview: article, isEphemeral : true)
        let (otrKey, sha256) = encryptLinkPreview(inMessage: message);
        
        syncMOC.zm_fileAssetCache.storeAssetData(message, format: .medium, encrypted: true, data: article.imageData.first!)
        _ = encryptLinkPreview(inMessage: message)
        message.linkPreviewState = .waitingToBeProcessed
        syncMOC.saveOrRollback()
        
        process(sut, message: message)
        let request = sut.nextRequest()
        
        let assetId = "id123"
        let token = "qJ8JPFLsiYGx7fnrlL+7Yk9="
        
        XCTAssertTrue(message.isEphemeral)

        // WHEN
        completeRequest(message, request: request, assetId: assetId, token: token)
        
        // THEN
        XCTAssertTrue(message.isEphemeral)
        XCTAssertTrue(message.genericMessage!.hasEphemeral())
        XCTAssertFalse(message.genericMessage!.hasText())

        let linkPreviews = message.genericMessage!.linkPreviews
        let articleProtocol: ZMArticle = linkPreviews.first!.article
        XCTAssertEqual(articleProtocol.image.uploaded.otrKey, otrKey)
        XCTAssertEqual(articleProtocol.image.uploaded.sha256, sha256)
        XCTAssertEqual(articleProtocol.image.uploaded.assetId, assetId)
        XCTAssertEqual(articleProtocol.image.uploaded.assetToken, token)
    }


}
