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
//  SecurityTokenClientProtocolExtensions.swift
//  SmokeAWSCredentials
//

import Foundation
import SecurityTokenClient
import SecurityTokenModel
import SmokeAWSCore
import LoggerAPI

enum AssumingRoleError: Error {
    case unableToAssumeRole(arn: String, error: Error)
    case noCredentialsReturned(arn: String)
}

extension SecurityTokenClientProtocol {
    /**
     Gets assumed role credentials from the SecurityTokenService. Returns nil
     if no assumed credentials could be obtained.
    
     - Parameters:
        - roleArn: the ARN of the role that is to be assumed.ARN
        - roleSessionName: the session name to use when assuming the role.
        - durationSeconds: The duration, in seconds, of the role session. The value can
            range from 900 seconds (15 minutes) to 3600 seconds (1 hour). By default, the value
            is set to 3600 seconds.
     */
    internal func getAssumedExpiringCredentials(roleArn: String,
                                                roleSessionName: String,
                                                durationSeconds: Int?) throws -> ExpiringCredentials {
        let input = SecurityTokenModel.AssumeRoleRequest(durationSeconds: durationSeconds,
                                                         roleArn: roleArn,
                                                         roleSessionName: roleSessionName)
        
        let output: SecurityTokenModel.AssumeRoleResponseForAssumeRole
        do {
            // call to assume the role
            output = try assumeRoleSync(input: input)
        } catch {
            throw AssumingRoleError.unableToAssumeRole(arn: roleArn, error: error)
        }
        
        guard let stsCredentials = output.assumeRoleResult.credentials else {
            throw AssumingRoleError.noCredentialsReturned(arn: roleArn)
        }
    
        return ExpiringCredentials(accessKeyId: stsCredentials.accessKeyId,
                                   expiration: stsCredentials.expiration.dateFromISO8601String ?? nil,
                                   secretAccessKey: stsCredentials.secretAccessKey,
                                   sessionToken: stsCredentials.sessionToken)
    }
    
    /**
     Function that retrieves StaticCredentials from the provided token service.
     */
    internal func getAssumedStaticCredentials(roleArn: String,
                                              roleSessionName: String) -> StaticCredentials? {
        let delegatedCredentials: ExpiringCredentials
        do {
            delegatedCredentials = try getAssumedExpiringCredentials(
                roleArn: roleArn,
                roleSessionName: roleSessionName,
                durationSeconds: nil)
        } catch {
            Log.warning("Unable to assumed delegated rotating credentials: \(error).")
    
            return nil
        }
        
        return StaticCredentials(accessKeyId: delegatedCredentials.accessKeyId,
                                 secretAccessKey: delegatedCredentials.secretAccessKey,
                                 sessionToken: delegatedCredentials.sessionToken)
    }
    
    /**
     Function that retrieves AssumedRotatingCredentials from the provided token service.
     */
    internal func getAssumedRotatingCredentials(roleArn: String,
                                                roleSessionName: String,
                                                durationSeconds: Int?) -> StoppableCredentialsProvider? {
        let delegatedCredentials: ExpiringCredentials
        do {
            delegatedCredentials = try getAssumedExpiringCredentials(
                roleArn: roleArn,
                roleSessionName: roleSessionName,
                durationSeconds: durationSeconds)
        } catch {
            Log.warning("Unable to assumed delegated rotating credentials: \(error).")
    
            return nil
        }
        
        let delegatedRotatingCredentials = AwsRotatingCredentialsProvider(expiringCredentials: delegatedCredentials)
    
        // if there is an expiry
        if let expiration = delegatedCredentials.expiration {
            func credentialsRetriever() throws -> ExpiringCredentials {
                return try getAssumedExpiringCredentials(
                    roleArn: roleArn,
                    roleSessionName: roleSessionName,
                    durationSeconds: durationSeconds)
            }
            
            delegatedRotatingCredentials.start(
                beforeExpiration: expiration,
                roleSessionName: roleSessionName,
                credentialsRetriever: credentialsRetriever)
        }
    
        return delegatedRotatingCredentials
    }
}

@available(OSX 10.12, *)
private let iso8601DateFormatter = ISO8601DateFormatter()

private extension String {
    /**
     Returns a date instance if this string is formatted according to
     ISO 8601 or nil otherwise. Used to schedule credential rotation.
     */
    var dateFromISO8601String: Date? {
        if #available(OSX 10.12, *) {
            return iso8601DateFormatter.date(from: self)
        } else {
            fatalError("Attempting to use ISO8601DateFormatter on an unsupported macOS version.")
        }
    }
}
