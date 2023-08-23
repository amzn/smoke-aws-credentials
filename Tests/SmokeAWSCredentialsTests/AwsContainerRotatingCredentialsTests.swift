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

@testable import SmokeAWSCredentials
import SmokeHTTPClient
import XCTest

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

private let dataRetrieverProvider1: (String) -> () throws -> Data = { _ in
    dataRetriever1
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

    func testGetAwsContainerCredentials() {
        // don't provide an expiration to avoid setting up a rotation timer in the test
        let nonExpiringCredentials = ExpiringCredentials(accessKeyId: TestVariables.accessKeyId,
                                                         expiration: nil,
                                                         secretAccessKey: TestVariables.secretAccessKey,
                                                         sessionToken: TestVariables.sessionToken)

        let data = try! jsonEncoder.encode(nonExpiringCredentials)

        let dataRetrieverProvider: (String) -> () throws -> Data = { _ in
            { data }
        }

        let environment = ["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI": "endpoint"]
        let credentialsProvider = AwsContainerRotatingCredentialsProvider.get(
            fromEnvironment: environment,
            reporting: MockCoreInvocationReporting(),
            dataRetrieverProvider: dataRetrieverProvider)!
        let credentials = credentialsProvider.credentials

        XCTAssertEqual(TestVariables.accessKeyId, credentials.accessKeyId)
        XCTAssertEqual(TestVariables.secretAccessKey, credentials.secretAccessKey)
        XCTAssertEqual(TestVariables.sessionToken, credentials.sessionToken)
    }

    func testStaticCredentials() {
        let environment = [
            "AWS_ACCESS_KEY_ID": TestVariables.accessKeyId,
            "AWS_SECRET_ACCESS_KEY": TestVariables.secretAccessKey,
            "AWS_SESSION_TOKEN": TestVariables.sessionToken
        ]
        let credentialsProvider = AwsContainerRotatingCredentialsProvider.get(
            fromEnvironment: environment,
            reporting: MockCoreInvocationReporting(),
            dataRetrieverProvider: dataRetrieverProvider1)!
        let credentials = credentialsProvider.credentials

        XCTAssertEqual(TestVariables.accessKeyId, credentials.accessKeyId)
        XCTAssertEqual(TestVariables.secretAccessKey, credentials.secretAccessKey)
        XCTAssertEqual(TestVariables.sessionToken, credentials.sessionToken)
    }

    func testNoCredentials() {
        let credentialsProvider = AwsContainerRotatingCredentialsProvider.get(
            fromEnvironment: [:],
            reporting: MockCoreInvocationReporting(),
            dataRetrieverProvider: dataRetrieverProvider1)

        XCTAssertNil(credentialsProvider)
    }

    static var allTests = [
        ("testGetCredentials", testGetCredentials),
        ("testGetInvalidCredentials", testGetInvalidCredentials),
        ("testGetAwsContainerCredentials", testGetAwsContainerCredentials),
        ("testStaticCredentials", testStaticCredentials),
        ("testNoCredentials", testNoCredentials),
    ]
}
