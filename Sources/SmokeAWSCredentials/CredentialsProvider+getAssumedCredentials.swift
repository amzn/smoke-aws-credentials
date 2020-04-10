// Copyright 2018-2020 Amazon.com, Inc. or its affiliates. All Rights Reserved.
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
//  CredentialsProvider+getAssumedCredentials.swift
//  SmokeAWSCredentials
//

import Foundation
import SmokeAWSCore
import SmokeAWSHttp
import SecurityTokenClient
import SmokeHTTPClient
import AsyncHTTPClient
import Logging

public extension SmokeAWSCore.CredentialsProvider {
    
    /**
        Function to get assumed role credentials that will not track expiration and rotate.
    
        - Parameters:
           - roleArn: the ARN of the role that is to be assumed.
           - roleSessionName: the session name to use when assuming the role.
           - logger: the logger instance to use when reporting on obtaining these credentials.
           - retryConfiguration: the client retry configuration to use to get the credentials.
                                 If not present, the default configuration will be used.
        */
       func getAssumedStaticCredentials(
               roleArn: String,
               roleSessionName: String,
               logger: Logging.Logger = Logger(label: "com.amazon.SmokeAWSCredentials"),
               retryConfiguration: HTTPClientRetryConfiguration = .default) -> StaticCredentials? {
           return getAssumedStaticCredentials(roleArn: roleArn,
                                              roleSessionName: roleSessionName,
                                              logger: logger,
                                              traceContext: AWSClientInvocationTraceContext(),
                                              retryConfiguration: retryConfiguration)
       }
    
    /**
     Function to get assumed role credentials that will not track expiration and rotate.
 
     - Parameters:
        - roleArn: the ARN of the role that is to be assumed.
        - roleSessionName: the session name to use when assuming the role.
        - logger: the logger instance to use when reporting on obtaining these credentials.
        - traceContext: the trace context to use when reporting on obtaining these credentials.
        - retryConfiguration: the client retry configuration to use to get the credentials.
                              If not present, the default configuration will be used.
     */
    func getAssumedStaticCredentials<TraceContextType: InvocationTraceContext>(
            roleArn: String,
            roleSessionName: String,
            logger: Logging.Logger = Logger(label: "com.amazon.SmokeAWSCredentials"),
            traceContext: TraceContextType,
            retryConfiguration: HTTPClientRetryConfiguration = .default) -> StaticCredentials? {
        var credentialsLogger = logger
        credentialsLogger[metadataKey: "credentials.source"] = "assumed.\(roleSessionName)"
        let reporting = CredentialsInvocationReporting(logger: credentialsLogger,
                                                       internalRequestId: "credentials.assumed.\(roleSessionName)",
                                                       traceContext: traceContext)
        
        return AWSSecurityTokenClient<CredentialsInvocationReporting<TraceContextType>>.getAssumedStaticCredentials(
            roleArn: roleArn,
            roleSessionName: roleSessionName,
            credentialsProvider: self,
            reporting: reporting,
            retryConfiguration: retryConfiguration)
    }
    
    /**
        Function to get assumed role credentials that will track expiration and rotate.
    
        - Parameters:
           - roleArn: the ARN of the role that is to be assumed.
           - roleSessionName: the session name to use when assuming the role.
           - durationSeconds: The duration, in seconds, of the role session. The value can
               range from 900 seconds (15 minutes) to 3600 seconds (1 hour). By default, the value
               is set to 3600 seconds.
           - logger: the logger instance to use when reporting on obtaining these credentials.
           - retryConfiguration: the client retry configuration to use to get the credentials.
                                 If not present, the default configuration will be used.
           - eventLoopProvider: the provider of the event loop for obtaining these credentials.
        */
       func getAssumedRotatingCredentials(
               roleArn: String,
               roleSessionName: String,
               durationSeconds: Int?,
               logger: Logging.Logger = Logger(label: "com.amazon.SmokeAWSCredentials"),
               retryConfiguration: HTTPClientRetryConfiguration = .default,
               eventLoopProvider: HTTPClient.EventLoopGroupProvider = .createNew) -> StoppableCredentialsProvider? {
            return getAssumedRotatingCredentials(
                roleArn: roleArn,
                roleSessionName: roleSessionName,
                durationSeconds: durationSeconds,
                logger: logger,
                traceContext: AWSClientInvocationTraceContext(),
                retryConfiguration: retryConfiguration,
                eventLoopProvider: eventLoopProvider)
       }
    
    /**
     Function to get assumed role credentials that will track expiration and rotate.
 
     - Parameters:
        - roleArn: the ARN of the role that is to be assumed.
        - roleSessionName: the session name to use when assuming the role.
        - durationSeconds: The duration, in seconds, of the role session. The value can
            range from 900 seconds (15 minutes) to 3600 seconds (1 hour). By default, the value
            is set to 3600 seconds.
        - logger: the logger instance to use when reporting on obtaining these credentials.
        - traceContext: the trace context to use when reporting on obtaining these credentials.
        - retryConfiguration: the client retry configuration to use to get the credentials.
                              If not present, the default configuration will be used.
        - eventLoopProvider: the provider of the event loop for obtaining these credentials.
     */
    func getAssumedRotatingCredentials<TraceContextType: InvocationTraceContext>(
            roleArn: String,
            roleSessionName: String,
            durationSeconds: Int?,
            logger: Logging.Logger = Logger(label: "com.amazon.SmokeAWSCredentials"),
            traceContext: TraceContextType,
            retryConfiguration: HTTPClientRetryConfiguration = .default,
            eventLoopProvider: HTTPClient.EventLoopGroupProvider = .createNew) -> StoppableCredentialsProvider? {
        var credentialsLogger = logger
        credentialsLogger[metadataKey: "credentials.source"] = "assumed.\(roleSessionName)"
        let reporting = CredentialsInvocationReporting(logger: credentialsLogger,
                                                       internalRequestId: "credentials.assumed.\(roleSessionName)",
                                                       traceContext: traceContext)
        
        return AWSSecurityTokenClient<CredentialsInvocationReporting<TraceContextType>>.getAssumedRotatingCredentials(
            roleArn: roleArn,
            roleSessionName: roleSessionName,
            credentialsProvider: self,
            durationSeconds: durationSeconds,
            reporting: reporting,
            retryConfiguration: retryConfiguration,
            eventLoopProvider: eventLoopProvider)
    }
}
