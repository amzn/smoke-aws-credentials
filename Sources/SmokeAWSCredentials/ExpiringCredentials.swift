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
//  ExpiringCredentials.swift
//  SmokeAWSCredentials
//

import Foundation
import SmokeAWSCore

/**
 Structure that holds and is used to decode the response from AWS Metadata service.
 */
public struct ExpiringCredentials: Codable, SmokeAWSCore.Credentials {
    public let accessKeyId: String
    public let expiration: Date?
    public let secretAccessKey: String
    public let sessionToken: String?
    
    private static let jsonDecoder: JSONDecoder = {
        let jsonDecoder = JSONDecoder()

        if #available(OSX 10.12, *) {
            jsonDecoder.dateDecodingStrategy = .iso8601
        }
        
        return jsonDecoder
    }()
    
    enum CodingKeys: String, CodingKey {
        case accessKeyId = "AccessKeyId"
        case expiration = "Expiration"
        case secretAccessKey = "SecretAccessKey"
        case sessionTokenAsToken = "Token"
        case sessionTokenAsSessionToken = "SessionToken"
    }
    
    public init(accessKeyId: String,
                expiration: Date?,
                secretAccessKey: String,
                sessionToken: String?) {
        self.accessKeyId = accessKeyId
        self.expiration = expiration
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
    
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accessKeyId = try values.decode(String.self, forKey: .accessKeyId)
        expiration = try values.decodeIfPresent(Date.self, forKey: .expiration)
        secretAccessKey = try values.decode(String.self, forKey: .secretAccessKey)
        
        // the session token may be in the field "Token" or "SessionToken"
        if let sessionTokenAsToken = try values.decodeIfPresent(String.self,
                                                                forKey: .sessionTokenAsToken) {
            sessionToken = sessionTokenAsToken
        } else {
            sessionToken = try values.decodeIfPresent(String.self,
                                                      forKey: .sessionTokenAsSessionToken)
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessKeyId, forKey: .accessKeyId)
        try container.encode(expiration, forKey: .expiration)
        try container.encode(secretAccessKey, forKey: .secretAccessKey)
        try container.encode(sessionToken, forKey: .sessionTokenAsToken)
    }
    
    static func getCurrentCredentials(dataRetriever: () throws -> Data) throws -> ExpiringCredentials {
        let data = try dataRetriever()
        
        return try jsonDecoder.decode(ExpiringCredentials.self, from: data)
    }
}
