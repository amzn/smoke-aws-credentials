// Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
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

private let data = try! jsonEncoder.encode(expiringCredentials)

private let dataRetriever: () throws -> Data = {
    return data
}
private let dataRetrieverProvider: (String) -> () throws -> Data = { credentialsPath in
    return dataRetriever
}

class AwsContainerRotatingCredentialsTests: XCTestCase {
    func testGetCredentials() throws {
         let credentials = try ExpiringCredentials.getCurrentCredentials(dataRetriever: dataRetriever)
        
         XCTAssertEqual(TestVariables.accessKeyId, credentials.accessKeyId)
         XCTAssertEqual(TestVariables.secretAccessKey, credentials.secretAccessKey)
         XCTAssertEqual(TestVariables.sessionToken, credentials.sessionToken)
         XCTAssertEqual(expiration, credentials.expiration!)
     }
    
    func testGetAwsContainerCredentials() {
        // don't provide an expiration to avoid setting up a rotation timer in the test
        let nonExpiringCredentials = ExpiringCredentials(accessKeyId: TestVariables.accessKeyId,
                                                         expiration: nil,
                                                         secretAccessKey: TestVariables.secretAccessKey,
                                                         sessionToken: TestVariables.sessionToken)
        
        let data = try! jsonEncoder.encode(nonExpiringCredentials)

        let dataRetrieverProvider: (String) -> () throws -> Data = { credentialsPath in
            return { return data }
        }
        
        let environment = ["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI": "endpoint"]
        let credentialsProvider = AwsContainerRotatingCredentialsProvider.get(fromEnvironment: environment,
                                                                                 dataRetrieverProvider: dataRetrieverProvider)!
        let credentials = credentialsProvider.credentials
        
        XCTAssertEqual(TestVariables.accessKeyId, credentials.accessKeyId)
        XCTAssertEqual(TestVariables.secretAccessKey, credentials.secretAccessKey)
        XCTAssertEqual(TestVariables.sessionToken, credentials.sessionToken)
    }
    
    func testStaticCredentials() {
        let environment = ["AWS_ACCESS_KEY_ID": TestVariables.accessKeyId,
                           "AWS_SECRET_ACCESS_KEY": TestVariables.secretAccessKey,
                           "AWS_SESSION_TOKEN": TestVariables.sessionToken]
        let credentialsProvider = AwsContainerRotatingCredentialsProvider.get(fromEnvironment: environment,
                                                                                 dataRetrieverProvider: dataRetrieverProvider)!
        let credentials = credentialsProvider.credentials
        
        XCTAssertEqual(TestVariables.accessKeyId, credentials.accessKeyId)
        XCTAssertEqual(TestVariables.secretAccessKey, credentials.secretAccessKey)
        XCTAssertEqual(TestVariables.sessionToken, credentials.sessionToken)
    }
 
    func testNoCredentials() {
        let credentialsProvider = AwsContainerRotatingCredentialsProvider.get(fromEnvironment: [:],
                                                                                 dataRetrieverProvider: dataRetrieverProvider)
        
        XCTAssertNil(credentialsProvider)
    }

    static var allTests = [
        ("testGetCredentials", testGetCredentials),
        ("testGetAwsContainerCredentials", testGetAwsContainerCredentials),
        ("testStaticCredentials", testStaticCredentials),
        ("testNoCredentials", testNoCredentials),
    ]
}

