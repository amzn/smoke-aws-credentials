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
//  SmokeAWSCredentialsTests.swift
//  SmokeAWSCredentials
//

import XCTest
@testable import SmokeAWSCredentials
import SecurityTokenClient
import SecurityTokenModel
import SmokeAWSCore

@available(OSX 10.12, *)
private let iso8601DateFormatter = ISO8601DateFormatter()

extension Date {
    var iso8601: String {
        if #available(OSX 10.12, *) {
            return iso8601DateFormatter.string(from: self)
        } else {
            fatalError("Attempting to use ISO8601DateFormatter on an unsupported macOS version.")
        }
    }
}

class SmokeAWSCredentialsTests: XCTestCase {
    func getAssumeRoleSync()
    -> SecurityTokenClientProtocol.AssumeRoleSyncType {
        let expiration = Date(timeIntervalSinceNow: 305)
        let expiryString = expiration.iso8601
        
        func assumeRoleSync(input: SecurityTokenModel.AssumeRoleRequest) throws -> SecurityTokenModel.AssumeRoleResponseForAssumeRole {
            let credentials = SecurityTokenModel.Credentials(accessKeyId: TestVariables.accessKeyId,
                                                             expiration: expiryString,
                                                             secretAccessKey: TestVariables.secretAccessKey,
                                                             sessionToken: TestVariables.sessionToken)
            
            let assumeRoleResult = SecurityTokenModel.AssumeRoleResponse(
                assumedRoleUser: nil,
                credentials: credentials,
                packedPolicySize: nil)
            
            return SecurityTokenModel.AssumeRoleResponseForAssumeRole(assumeRoleResult: assumeRoleResult)
        }
        
        return assumeRoleSync
    }
    
    func testRotatingGetCredentials() {
        let client = MockSecurityTokenClient(assumeRoleSync: getAssumeRoleSync())
        guard let delegatedRotatingCredentials =
            client.getAssumedRotatingCredentials(roleArn: "arn:aws:iam::XXXXXXXXXXXX:role/theRole",
                                                 roleSessionName: "mySession", durationSeconds: 3600) else {
                                                    return XCTFail()
        }
        
        let credentials = delegatedRotatingCredentials.credentials
        XCTAssertEqual(TestVariables.accessKeyId, credentials.accessKeyId)
        XCTAssertEqual(TestVariables.secretAccessKey, credentials.secretAccessKey)
        XCTAssertEqual(TestVariables.sessionToken, credentials.sessionToken)
        
        delegatedRotatingCredentials.stop()
        delegatedRotatingCredentials.wait()
    }
    
    func testStaticGetCredentials() {
        let client = MockSecurityTokenClient(assumeRoleSync: getAssumeRoleSync())
        guard let delegatedRotatingCredentials =
            client.getAssumedStaticCredentials(roleArn: "arn:aws:iam::XXXXXXXXXXXX:role/theRole",
                                               roleSessionName: "mySession") else {
                                                return XCTFail()
        }
        
        let credentials = delegatedRotatingCredentials.credentials
        XCTAssertEqual(TestVariables.accessKeyId, credentials.accessKeyId)
        XCTAssertEqual(TestVariables.secretAccessKey, credentials.secretAccessKey)
        XCTAssertEqual(TestVariables.sessionToken, credentials.sessionToken)
    }


    static var allTests = [
        ("testRotatingGetCredentials", testRotatingGetCredentials),
        ("testStaticGetCredentials", testStaticGetCredentials)
    ]
}
