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
//  TestConfiguration.swift
//  SmokeAWSCredentials
//

import Foundation
import SecurityTokenClient
import SecurityTokenModel
@testable import SmokeAWSCredentials

let jsonEncoder: JSONEncoder = {
    let jsonEncoder = JSONEncoder()

    if #available(OSX 10.12, *) {
        jsonEncoder.dateEncodingStrategy = .iso8601
    }
    jsonEncoder.outputFormatting = .prettyPrinted

    return jsonEncoder
}()

enum TestVariables {
    static let arn = "ARN"
    static let assumedRoleId = "assumedRoleId"
    static let accessKeyId = "accessKeyId"
    static let accessKeyId2 = "accessKeyId2"
    static let expiration = "4118-03-12T20:29:09Z"
    static let pastExpiration = "1918-03-12T20:29:09Z"
    static let secretAccessKey = "secretAccessKey"
    static let secretAccessKey2 = "secretAccessKey2"
    static let sessionToken = "sessionToken"
    static let sessionToken2 = "sessionToken2"
    static let nullString = "null"
}

let expiration = TestVariables.expiration.dateFromISO8601String!
let pastExpiration = TestVariables.pastExpiration.dateFromISO8601String!
let expiringCredentials = ExpiringCredentials(accessKeyId: TestVariables.accessKeyId,
                                              expiration: expiration,
                                              secretAccessKey: TestVariables.secretAccessKey,
                                              sessionToken: TestVariables.sessionToken)
let invalidCredentials1 = ExpiringCredentials(accessKeyId: TestVariables.nullString,
                                              expiration: expiration,
                                              secretAccessKey: TestVariables.nullString,
                                              sessionToken: TestVariables.nullString)
let invalidCredentials2 = ExpiringCredentials(accessKeyId: TestVariables.accessKeyId,
                                              expiration: pastExpiration,
                                              secretAccessKey: TestVariables.secretAccessKey,
                                              sessionToken: TestVariables.sessionToken)
