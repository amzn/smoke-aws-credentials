// Copyright 2018-2021 Amazon.com, Inc. or its affiliates. All Rights Reserved.
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
//  AwsContainerRotatingCredentialsTests.swift
//  SmokeAWSCredentials
//

import XCTest
@testable import SmokeAWSCredentials
import SmokeHTTPClient
import AsyncHTTPClient
import Logging

private let data1 = try! jsonEncoder.encode(expiringCredentials)
private let data2 = try! jsonEncoder.encode(invalidCredentials1)
private let data3 = try! jsonEncoder.encode(invalidCredentials2)

private let dataRetriever1: () throws -> Data = {
    return data1
}
private let dataRetriever2: () throws -> Data = {
    return data2
}
private let dataRetriever3: () throws -> Data = {
    return data3
}

private let dataRetrieverProvider1: (String) -> () throws -> Data = { credentialsPath in
    return dataRetriever1
}

internal struct TestExpiringCredentialsRetriever: DevExpiringCredentialsRetrieverProtocol, ContainerExpiringCredentialsRetrieverProtocol {
    init(iamRoleArn: String) {
        // nothing to do
    }
    
    init(eventLoopProvider: AsyncHTTPClient.HTTPClient.EventLoopGroupProvider, credentialsPath: String, logger: Logger) {
        XCTAssertEqual(credentialsPath, "endpoint")
    }
    
    
    func shutdown() async throws {
        // nothing to do
    }
    
    func close() throws {
        // nothing to do
    }
    
    func get() throws -> ExpiringCredentials {
        // don't provide an expiration to avoid setting up a rotation timer in the test
        return ExpiringCredentials(accessKeyId: TestVariables.accessKeyId,
                                   expiration: nil,
                                   secretAccessKey: TestVariables.secretAccessKey,
                                   sessionToken: TestVariables.sessionToken)
    }
    
    func getCredentials() throws -> ExpiringCredentials {
        return try get()
    }
}

class AwsContainerRotatingCredentialsTests: XCTestCase {
    func testGetCredentials() throws {
        let credentials = try ExpiringCredentials.getCurrentCredentials(dataRetriever: dataRetriever1)
        
        XCTAssertEqual(TestVariables.accessKeyId, credentials.accessKeyId)
        XCTAssertEqual(TestVariables.secretAccessKey, credentials.secretAccessKey)
        XCTAssertEqual(TestVariables.sessionToken, credentials.sessionToken)
        XCTAssertEqual(expiration, credentials.expiration!)
    }
    
    func testGetInvalidCredentials() throws {
        do {
            _ = try ExpiringCredentials.getCurrentCredentials(dataRetriever: dataRetriever2)
            
            XCTFail("Expected failure didn't occur.")
        } catch SmokeAWSCredentialsError.missingCredentials {
            // expected error
        } catch {
            XCTFail("Unexpected failure occurred: '\(error)'.")
        }
    }
    
    func testGetInvalidDateCredentials() throws {
        do {
            _ = try ExpiringCredentials.getCurrentCredentials(dataRetriever: dataRetriever3)
            
            XCTFail("Expected failure didn't occur.")
        } catch SmokeAWSCredentialsError.missingCredentials {
            // expected error
        } catch {
            XCTFail("Unexpected failure occurred: '\(error)'.")
        }
    }
    
    @available(swift, deprecated: 3.0, message: "Testing AwsContainerRotatingCredentialsProvider")
    func testGetAwsContainerCredentials() {
        let environment = ["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI": "endpoint"]
        let credentialsProvider = AwsContainerRotatingCredentialsProvider.get(fromEnvironment: environment,
                                                                              containerRetrieverType: TestExpiringCredentialsRetriever.self,
                                                                              devRetrieverType: TestExpiringCredentialsRetriever.self)!
        let credentials = credentialsProvider.credentials
        
        XCTAssertEqual(TestVariables.accessKeyId, credentials.accessKeyId)
        XCTAssertEqual(TestVariables.secretAccessKey, credentials.secretAccessKey)
        XCTAssertEqual(TestVariables.sessionToken, credentials.sessionToken)
    }
    
    @available(swift, deprecated: 3.0, message: "Testing AwsContainerRotatingCredentialsProvider")
    func testStaticCredentials() {
        let environment = ["AWS_ACCESS_KEY_ID": TestVariables.accessKeyId,
                           "AWS_SECRET_ACCESS_KEY": TestVariables.secretAccessKey,
                           "AWS_SESSION_TOKEN": TestVariables.sessionToken]
        let credentialsProvider = AwsContainerRotatingCredentialsProvider.get(fromEnvironment: environment,
                                                                              containerRetrieverType: TestExpiringCredentialsRetriever.self,
                                                                              devRetrieverType: TestExpiringCredentialsRetriever.self)!
        let credentials = credentialsProvider.credentials
        
        XCTAssertEqual(TestVariables.accessKeyId, credentials.accessKeyId)
        XCTAssertEqual(TestVariables.secretAccessKey, credentials.secretAccessKey)
        XCTAssertEqual(TestVariables.sessionToken, credentials.sessionToken)
    }
 
    @available(swift, deprecated: 3.0, message: "Testing AwsContainerRotatingCredentialsProvider")
    func testNoCredentials() {
        let credentialsProvider = AwsContainerRotatingCredentialsProvider.get(fromEnvironment: [:],
                                                                              containerRetrieverType: TestExpiringCredentialsRetriever.self,
                                                                              devRetrieverType: TestExpiringCredentialsRetriever.self)
        
        XCTAssertNil(credentialsProvider)
    }
    
    func testGetAwsContainerCredentialsV2() async {
        let environment = ["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI": "endpoint"]
        let credentialsProvider = await AwsContainerRotatingCredentialsProviderV2.get(fromEnvironment: environment,
                                                                                      containerRetrieverType: TestExpiringCredentialsRetriever.self,
                                                                                      devRetrieverType: TestExpiringCredentialsRetriever.self)!
        let credentials = credentialsProvider.credentials
        
        XCTAssertEqual(TestVariables.accessKeyId, credentials.accessKeyId)
        XCTAssertEqual(TestVariables.secretAccessKey, credentials.secretAccessKey)
        XCTAssertEqual(TestVariables.sessionToken, credentials.sessionToken)
    }
    
    func testStaticCredentialsV2() async {
        let environment = ["AWS_ACCESS_KEY_ID": TestVariables.accessKeyId,
                           "AWS_SECRET_ACCESS_KEY": TestVariables.secretAccessKey,
                           "AWS_SESSION_TOKEN": TestVariables.sessionToken]
        let credentialsProvider = await AwsContainerRotatingCredentialsProviderV2.get(fromEnvironment: environment,
                                                                                      containerRetrieverType: TestExpiringCredentialsRetriever.self,
                                                                                      devRetrieverType: TestExpiringCredentialsRetriever.self)!
        let credentials = credentialsProvider.credentials
        
        XCTAssertEqual(TestVariables.accessKeyId, credentials.accessKeyId)
        XCTAssertEqual(TestVariables.secretAccessKey, credentials.secretAccessKey)
        XCTAssertEqual(TestVariables.sessionToken, credentials.sessionToken)
    }
 
    func testNoCredentialsV2() async {
        let credentialsProvider = await AwsContainerRotatingCredentialsProviderV2.get(fromEnvironment: [:],
                                                                                      containerRetrieverType: TestExpiringCredentialsRetriever.self,
                                                                                      devRetrieverType: TestExpiringCredentialsRetriever.self)
        
        XCTAssertNil(credentialsProvider)
    }
}

