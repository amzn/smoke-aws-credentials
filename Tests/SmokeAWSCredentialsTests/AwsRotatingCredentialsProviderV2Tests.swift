// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// You may not use this file except in compliance with the License.
// A copy of the License is located at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// or in the "license" file accompanying this file. This file is distributed
// on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
// express or implied. See the License for the specific language governing
// permissions and limitations under the License.
//
//  AwsContainerRotatingCredentialsV2Tests.swift
//  SmokeAWSCredentials
//

import Logging
@testable import SmokeAWSCredentials
import SmokeHTTPClient
import XCTest
import Logging
import SmokeAWSCore

private enum TestErrors: Swift.Error {
    case retrieverError
}

private actor TestExpiringCredentialsAsyncRetriever: ExpiringCredentialsAsyncRetriever {
    enum Result {
        case credentials(SmokeAWSCredentials.ExpiringCredentials)
        case error(Swift.Error)
    }
    var results: [Result]
    
    init(results: [Result]) {
        self.results = results.reversed()
    }
    func getCredentials() async throws -> SmokeAWSCredentials.ExpiringCredentials {
        let result = self.results.popLast()!
        
        switch result {
        case .credentials(let expiringCredentials):
            return expiringCredentials
        case .error(let error):
            throw error
        }
    }
    
    nonisolated func close() throws {
        // nothing to do
    }
    
    func shutdown() async throws {
        // nothing to do
    }
    nonisolated func get() throws -> SmokeAWSCredentials.ExpiringCredentials {
        fatalError("Not implemented")
    }
    
    
}

class AwsContainerRotatingCredentialsV2Tests: XCTestCase {
    private let accessKeyId1 = "accessKeyId1"
    private let accessKeyId2 = "accessKeyId2"
    private let accessKeyId3 = "accessKeyId3"
    private let secretAccessKey1 = "secretAccessKey1"
    private let secretAccessKey2 = "secretAccessKey2"
    private let secretAccessKey3 = "secretAccessKey3"
    private let sessionToken1 = "sessionToken1"
    private let sessionToken2 = "sessionToken2"
    private let sessionToken3 = "sessionToken3"
    
    func testBackgroundRefresh() async throws {
        let firstCredentials = SmokeAWSCredentials.ExpiringCredentials(accessKeyId: accessKeyId1,
                                                                       expiration: Date() + 10,
                                                                       secretAccessKey: secretAccessKey1,
                                                                       sessionToken: sessionToken1)
        let secondCredentials = SmokeAWSCredentials.ExpiringCredentials(accessKeyId: accessKeyId2,
                                                                       expiration: Date() + 20,
                                                                       secretAccessKey: secretAccessKey2,
                                                                       sessionToken: sessionToken2)
        let thirdCredentials = SmokeAWSCredentials.ExpiringCredentials(accessKeyId: accessKeyId3,
                                                                       expiration: Date() + 3600,
                                                                       secretAccessKey: secretAccessKey3,
                                                                       sessionToken: sessionToken3)
        
        let retriever = TestExpiringCredentialsAsyncRetriever(results: [.credentials(firstCredentials),
                                                                        .credentials(secondCredentials),
                                                                        .credentials(thirdCredentials)])
        let provider = try await AwsRotatingCredentialsProviderV2(
            expiringCredentialsRetriever: retriever,
            roleSessionName: nil,
            logger: Logger(label: "test.logger"),
            expirationBufferSeconds: 2,
            backgroundExpirationBufferSeconds: 5)
        
        provider.start()
        
        // will return credentials retrieved from the first time the credentials are called
        let retrievedCredentials1 = try await provider.getCredentials()
        XCTAssertEqual(retrievedCredentials1.accessKeyId, firstCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials1.secretAccessKey, firstCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials1.sessionToken, firstCredentials.sessionToken)
        
        
        // legacy property should match
        let retrievedCredentials1_1 = provider.credentials
        XCTAssertEqual(retrievedCredentials1_1.accessKeyId, firstCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials1_1.secretAccessKey, firstCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials1_1.sessionToken, firstCredentials.sessionToken)
        
        // the background credentials refresh should happen after 5 seconds (five seconds before the expiration)
        try await Task.sleep(for: .seconds(6))
        
        // will return credentials retrieved from the background refresh
        // even through the first credentials haven't expired yet
        let retrievedCredentials2 = try await provider.getCredentials()
        XCTAssertEqual(retrievedCredentials2.accessKeyId, secondCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials2.secretAccessKey, secondCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials2.sessionToken, secondCredentials.sessionToken)
        
        // legacy property should match
        let retrievedCredentials2_1 = provider.credentials
        XCTAssertEqual(retrievedCredentials2_1.accessKeyId, secondCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials2_1.secretAccessKey, secondCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials2_1.sessionToken, secondCredentials.sessionToken)
        
        // sleep until after the first credentials have expired
        try await Task.sleep(for: .seconds(6))
        
        // should still be the second credentials
        let retrievedCredentials3 = try await provider.getCredentials()
        XCTAssertEqual(retrievedCredentials3.accessKeyId, secondCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials3.secretAccessKey, secondCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials3.sessionToken, secondCredentials.sessionToken)
        
        // legacy property should match
        let retrievedCredentials3_1 = provider.credentials
        XCTAssertEqual(retrievedCredentials3_1.accessKeyId, secondCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials3_1.secretAccessKey, secondCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials3_1.sessionToken, secondCredentials.sessionToken)
        
        // the next background credentials refresh should happen after 15 seconds (five seconds before the expiration)
        try await Task.sleep(for: .seconds(4))
        
        // will return credentials retrieved from the second background refresh
        // even through the second credentials haven't expired yet
        let retrievedCredentials4 = try await provider.getCredentials()
        XCTAssertEqual(retrievedCredentials4.accessKeyId, thirdCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials4.secretAccessKey, thirdCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials4.sessionToken, thirdCredentials.sessionToken)
        
        // legacy property should match
        let retrievedCredentials4_1 = provider.credentials
        XCTAssertEqual(retrievedCredentials4_1.accessKeyId, thirdCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials4_1.secretAccessKey, thirdCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials4_1.sessionToken, thirdCredentials.sessionToken)
        
        // sleep until after the second credentials have expired
        try await Task.sleep(for: .seconds(6))
        
        // should still be the third credentials
        let retrievedCredentials5 = try await provider.getCredentials()
        XCTAssertEqual(retrievedCredentials5.accessKeyId, thirdCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials5.secretAccessKey, thirdCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials5.sessionToken, thirdCredentials.sessionToken)
        
        // legacy property should match
        let retrievedCredentials5_1 = provider.credentials
        XCTAssertEqual(retrievedCredentials5_1.accessKeyId, thirdCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials5_1.secretAccessKey, thirdCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials5_1.sessionToken, thirdCredentials.sessionToken)
        
        try await provider.shutdown()
        provider.wait()
    }
    
    func testFailedBackgroundRefresh() async throws {
        let firstCredentials = SmokeAWSCredentials.ExpiringCredentials(accessKeyId: accessKeyId1,
                                                                       expiration: Date() + 10,
                                                                       secretAccessKey: secretAccessKey1,
                                                                       sessionToken: sessionToken1)
        let secondCredentials = SmokeAWSCredentials.ExpiringCredentials(accessKeyId: accessKeyId2,
                                                                       expiration: Date() + 20,
                                                                       secretAccessKey: secretAccessKey2,
                                                                       sessionToken: sessionToken2)
        let thirdCredentials = SmokeAWSCredentials.ExpiringCredentials(accessKeyId: accessKeyId3,
                                                                       expiration: Date() + 3600,
                                                                       secretAccessKey: secretAccessKey3,
                                                                       sessionToken: sessionToken3)
        
        let retriever = TestExpiringCredentialsAsyncRetriever(results: [.credentials(firstCredentials),
                                                                        .error(TestErrors.retrieverError),
                                                                        .credentials(secondCredentials),
                                                                        .credentials(thirdCredentials)])
        let provider = try await AwsRotatingCredentialsProviderV2(
            expiringCredentialsRetriever: retriever,
            roleSessionName: nil,
            logger: Logger(label: "test.logger"),
            expirationBufferSeconds: 2,
            backgroundExpirationBufferSeconds: 5)
        
        provider.start()
        
        // will return credentials retrieved from the first time the credentials are called
        let retrievedCredentials1 = try await provider.getCredentials()
        XCTAssertEqual(retrievedCredentials1.accessKeyId, firstCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials1.secretAccessKey, firstCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials1.sessionToken, firstCredentials.sessionToken)
        
        // the background credentials refresh should happen after 5 seconds (five seconds before the expiration)
        try await Task.sleep(for: .seconds(6))
        
        // will return the first credentials as the background refresh failed
        // and not within expirationBufferSeconds of the credentials expiry
        let retrievedCredentials2 = try await provider.getCredentials()
        XCTAssertEqual(retrievedCredentials2.accessKeyId, firstCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials2.secretAccessKey, firstCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials2.sessionToken, firstCredentials.sessionToken)
        
        // sleep to within the expirationBufferSeconds
        try await Task.sleep(for: .seconds(3))
        
        // will actually go and retrieve refreshed credentials
        let retrievedCredentials2_2 = try await provider.getCredentials()
        XCTAssertEqual(retrievedCredentials2_2.accessKeyId, secondCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials2_2.secretAccessKey, secondCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials2_2.sessionToken, secondCredentials.sessionToken)
        
        // sleep until after the first credentials have expired
        try await Task.sleep(for: .seconds(3))
        
        // should still be the second credentials
        let retrievedCredentials3 = try await provider.getCredentials()
        XCTAssertEqual(retrievedCredentials3.accessKeyId, secondCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials3.secretAccessKey, secondCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials3.sessionToken, secondCredentials.sessionToken)
        
        // the next background credentials refresh should happen after 15 seconds (five seconds before the expiration)
        // the failure of the first background refresh shound not impact this occurring
        try await Task.sleep(for: .seconds(4))
        
        // will return credentials retrieved from the second background refresh
        // even through the second credentials haven't expired yet
        let retrievedCredentials4 = try await provider.getCredentials()
        XCTAssertEqual(retrievedCredentials4.accessKeyId, thirdCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials4.secretAccessKey, thirdCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials4.sessionToken, thirdCredentials.sessionToken)
        
        // sleep until after the second credentials have expired
        try await Task.sleep(for: .seconds(6))
        
        // should still be the third credentials
        let retrievedCredentials5 = try await provider.getCredentials()
        XCTAssertEqual(retrievedCredentials5.accessKeyId, thirdCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials5.secretAccessKey, thirdCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials5.sessionToken, thirdCredentials.sessionToken)
        
        try await provider.shutdown()
        provider.wait()
    }
    
    func testFailedRetrieval() async throws {
        let firstCredentials = SmokeAWSCredentials.ExpiringCredentials(accessKeyId: accessKeyId1,
                                                                       expiration: Date() + 10,
                                                                       secretAccessKey: secretAccessKey1,
                                                                       sessionToken: sessionToken1)
        
        let retriever = TestExpiringCredentialsAsyncRetriever(results: [.credentials(firstCredentials),
                                                                        .error(TestErrors.retrieverError),
                                                                        .error(TestErrors.retrieverError)])
        let provider = try await AwsRotatingCredentialsProviderV2(
            expiringCredentialsRetriever: retriever,
            roleSessionName: nil,
            logger: Logger(label: "test.logger"),
            expirationBufferSeconds: 2,
            backgroundExpirationBufferSeconds: 5)
        
        provider.start()
        
        // will return credentials retrieved from the first time the credentials are called
        let retrievedCredentials1 = try await provider.getCredentials()
        XCTAssertEqual(retrievedCredentials1.accessKeyId, firstCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials1.secretAccessKey, firstCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials1.sessionToken, firstCredentials.sessionToken)
        
        // the background credentials refresh should happen after 5 seconds (five seconds before the expiration)
        try await Task.sleep(for: .seconds(6))
        
        // will return the first credentials as the background refresh failed
        // and not within expirationBufferSeconds of the credentials expiry
        let retrievedCredentials2 = try await provider.getCredentials()
        XCTAssertEqual(retrievedCredentials2.accessKeyId, firstCredentials.accessKeyId)
        XCTAssertEqual(retrievedCredentials2.secretAccessKey, firstCredentials.secretAccessKey)
        XCTAssertEqual(retrievedCredentials2.sessionToken, firstCredentials.sessionToken)
        
        // sleep to within the expirationBufferSeconds
        try await Task.sleep(for: .seconds(3))
        
        // will actually go and retrieve refreshed credentials
        do {
            _ = try await provider.getCredentials()
            
            XCTFail("Expected error not thrown")
        } catch TestErrors.retrieverError {
            // expected error
        }
        
        try await provider.shutdown()
        provider.wait()
    }
}
