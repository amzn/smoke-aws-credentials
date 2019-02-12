// Copyright 2018-2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
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
@testable import SmokeAWSCredentials
import SecurityTokenClient
import SecurityTokenModel

let jsonEncoder: JSONEncoder = {
    let jsonEncoder = JSONEncoder()
    
    if #available(OSX 10.12, *) {
        jsonEncoder.dateEncodingStrategy = .iso8601
    }
    jsonEncoder.outputFormatting = .prettyPrinted
    
    return jsonEncoder
}()

struct TestVariables {
    static let arn = "ARN"
    static let assumedRoleId = "assumedRoleId"
    static let accessKeyId = "accessKeyId"
    static let expiration = "2118-03-12T20:29:09Z"
    static let secretAccessKey = "secretAccessKey"
    static let sessionToken = "sessionToken"
}

let expiration = Date(timeIntervalSince1970: 1522283216)
let expiringCredentials = ExpiringCredentials(accessKeyId: TestVariables.accessKeyId,
                                              expiration: expiration,
                                              secretAccessKey: TestVariables.secretAccessKey,
                                              sessionToken: TestVariables.sessionToken)
