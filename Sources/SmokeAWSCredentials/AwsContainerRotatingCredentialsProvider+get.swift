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
//  AwsContainerRotatingCredentials+get.swift
//  SmokeAWSCredentials
//

import Foundation
import SmokeAWSCore
import Logging
import SmokeHTTPClient
import AsyncHTTPClient

internal struct CredentialsInvocationReporting<TraceContextType: InvocationTraceContext>: HTTPClientCoreInvocationReporting {
    public let logger: Logger
    public var internalRequestId: String
    public var traceContext: TraceContextType
    
    public init(logger: Logger, internalRequestId: String, traceContext: TraceContextType) {
        self.logger = logger
        self.internalRequestId = internalRequestId
        self.traceContext = traceContext
    }
}

public typealias AwsContainerRotatingCredentialsProvider = AwsRotatingCredentialsProvider

enum CredentialsHTTPError: Error {
    case invalidEndpoint(String)
    case badResponse(String)
    case errorResponse(UInt, String?)
    case noResponse
}

public extension AwsContainerRotatingCredentialsProvider {
    // the endpoint for obtaining credentials from the ECS container
    // https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html
    private static let credentialsHost = "169.254.170.2"
    private static let credentialsPort = 80
    
    /**
     The Environment variable that can be passed in conjunction with
     the DEBUG compiler flag to gain credentials based on the
     IAM Role ARN specified.
 
     If this Environment variable and the DEBUG compiler flag are specified,
     this class will first attempt to obtain credentials from the container
     environment and then static credentials under the AWS_SECRET_ACCESS_KEY
     and AWS_ACCESS_KEY_ID keys. If neither are present, this class will call
     the shell script-
       /usr/local/bin/get-credentials.sh -r <role> -d <role lifetype>
     
     This script should write to its standard output a JSON structure capable of
     being decoded into the ExpiringCredentials structure.
     */
    static let devIamRoleArnEnvironmentVariable = "DEV_CREDENTIALS_IAM_ROLE_ARN"
 
    /**
     Static function that retrieves credentials provider from the specified environment -
     either rotating credentials retrieved from an endpoint specified under the
     AWS_CONTAINER_CREDENTIALS_RELATIVE_URI key or if that key isn't present,
     static credentials under the AWS_SECRET_ACCESS_KEY and AWS_ACCESS_KEY_ID keys.
     */
    static func get<TraceContextType: InvocationTraceContext>(
            fromEnvironment environment: [String: String] = ProcessInfo.processInfo.environment,
            logger: Logging.Logger,
            traceContext: TraceContextType,
            eventLoopProvider: HTTPClient.EventLoopGroupProvider = .createNew)
        -> StoppableCredentialsProvider? {
            var credentialsLogger = logger
            credentialsLogger[metadataKey: "credentials.source"] = "environment"
            let reporting = CredentialsInvocationReporting(logger: logger,
                                                           internalRequestId: "credentials.environment",
                                                           traceContext: traceContext)
            
            let dataRetrieverProvider: (String) -> () throws -> Data = { credentialsPath in
                return {
                    let completedSemaphore = DispatchSemaphore(value: 0)
                    var result: Result<HTTPClient.Response, Error>?
                    
                    let httpClient = HTTPClient(eventLoopGroupProvider: eventLoopProvider)
                    httpClient.get(url: "https://\(credentialsHost)/\(credentialsPath)").whenComplete { returnedResult in
                        result = returnedResult
                        completedSemaphore.signal()
                    }
                    
                    completedSemaphore.wait()
                    
                    guard let theResult = result else {
                        throw CredentialsHTTPError.noResponse
                    }
                    
                    switch theResult {
                    case .success(let response):
                        // if the response status is ok
                        if case .ok = response.status {
                            if var body = response.body {
                                let byteBufferSize = body.readableBytes
                                return body.readData(length: byteBufferSize) ?? Data()
                            } else {
                                return Data()
                            }
                        }
                        
                        let bodyAsString: String?
                        if var body = response.body {
                            let byteBufferSize = body.readableBytes
                            let data = body.readData(length: byteBufferSize) ?? Data()
                            
                            bodyAsString = String(data: data, encoding: .utf8)
                        } else {
                            bodyAsString = nil
                        }
                        
                        throw CredentialsHTTPError.errorResponse(response.status.code, bodyAsString)
                    case .failure(let error):
                        throw error
                    }
                }
            }
            
            return get(fromEnvironment: environment,
                       reporting: reporting,
                       dataRetrieverProvider: dataRetrieverProvider)
    }
    
    /**
     Internal static function for testing.
     */
    internal static func get<InvocationReportingType: HTTPClientCoreInvocationReporting>(
            fromEnvironment environment: [String: String],
            reporting: InvocationReportingType,
            dataRetrieverProvider: (String) -> () throws -> Data)
        -> StoppableCredentialsProvider? {
            var credentialsProvider: StoppableCredentialsProvider?
            if let rotatingCredentials = getRotatingCredentialsProvider(
                fromEnvironment: environment,
                reporting: reporting,
                dataRetrieverProvider: dataRetrieverProvider) {
                    credentialsProvider = rotatingCredentials
            }
            
            if credentialsProvider == nil,
                let staticCredentials = getStaticCredentialsProvider(
                    fromEnvironment: environment,
                    reporting: reporting,
                    dataRetrieverProvider: dataRetrieverProvider) {
                        credentialsProvider = staticCredentials
            }
            
            #if DEBUG
            if credentialsProvider == nil,
                let rotatingCredentials = getDevRotatingCredentialsProvider(
                    fromEnvironment: environment,
                    reporting: reporting) {
                    credentialsProvider = rotatingCredentials
            }
            #endif
            
            return credentialsProvider
    }
    
    private static func getStaticCredentialsProvider<InvocationReportingType: HTTPClientCoreInvocationReporting>(
        fromEnvironment environment: [String: String],
        reporting: InvocationReportingType,
        dataRetrieverProvider: (String) -> () throws -> Data)
        -> StoppableCredentialsProvider? {
            // get the values of the environment variables
            let awsAccessKeyId = environment["AWS_ACCESS_KEY_ID"]
            let awsSecretAccessKey = environment["AWS_SECRET_ACCESS_KEY"]
            let sessionToken = environment["AWS_SESSION_TOKEN"]
            
            guard let secretAccessKey = awsSecretAccessKey, let accessKeyId = awsAccessKeyId else {
                let logMessage = "'AWS_ACCESS_KEY_ID' and 'AWS_SESSION_TOKEN' environment variables not"
                    + "specified. Static credentials not available."
                reporting.logger.info("\(logMessage)")
                
                return nil
            }
            
            reporting.logger.debug("Static credentials retrieved from environment.")
            
            // return these credentials
            return SmokeAWSCore.StaticCredentials(accessKeyId: accessKeyId,
                                                  secretAccessKey: secretAccessKey,
                                                  sessionToken: sessionToken)
    }
    
#if DEBUG
    private static func getDevRotatingCredentialsProvider<InvocationReportingType: HTTPClientCoreInvocationReporting>(
            fromEnvironment environment: [String: String],
            reporting: InvocationReportingType) -> StoppableCredentialsProvider? {
        // get the values of the environment variables
        let devCredentialsIamRoleArn = environment["DEV_CREDENTIALS_IAM_ROLE_ARN"]
        
        guard let iamRoleArn = devCredentialsIamRoleArn else {
            let logMessage = "'DEV_CREDENTIALS_IAM_ROLE_ARN' environment variable not specified."
                + " Dev rotating credentials not available."
            
            reporting.logger.info("\(logMessage)")
            
            return nil
        }
        
        let dataRetriever: () throws -> Data = {
            let outputPipe = Pipe()
            
            let task = Process()
            #if os(Linux) && (swift(>=5.0) || (swift(>=4.1.50) && !swift(>=4.2)) || (swift(>=3.5) && !swift(>=4.0)))
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            #else
            task.launchPath = "/usr/bin/env"
            #endif
            task.arguments = ["/usr/local/bin/get-credentials.sh",
                              "-r",
                              iamRoleArn,
                              "-d",
                              "900"]
            task.standardOutput = outputPipe
            #if os(Linux) && swift(>=5.0)
            try task.run()
            #else
            task.launch()
            #endif
            task.waitUntilExit()

            return outputPipe.fileHandleForReading.availableData
        }
        
        let rotatingCredentialsProvider: StoppableCredentialsProvider
        do {
            rotatingCredentialsProvider = try createRotatingCredentialsProvider(
                reporting: reporting, dataRetriever: dataRetriever)
        } catch {
            reporting.logger.error("Retrieving dev rotating credentials rotation failed: '\(error)'")
            
            return nil
        }
        
        return rotatingCredentialsProvider
    }
#endif
    
    private static func getRotatingCredentialsProvider<InvocationReportingType: HTTPClientCoreInvocationReporting>(
        fromEnvironment environment: [String: String],
        reporting: InvocationReportingType,
        dataRetrieverProvider: (String) -> () throws -> Data)
        -> StoppableCredentialsProvider? {
        // get the values of the environment variables
        let awsContainerCredentialsRelativeUri = environment["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"]
        
        guard let credentialsPath = awsContainerCredentialsRelativeUri else {
            let logMessage = "'AWS_CONTAINER_CREDENTIALS_RELATIVE_URI' environment variable not specified."
                + " Rotating credentials not available."
            
            reporting.logger.info("\(logMessage)")
            
            return nil
        }
        
        let dataRetriever = dataRetrieverProvider(credentialsPath)
        let rotatingCredentialsProvider: StoppableCredentialsProvider
        do {
            rotatingCredentialsProvider = try createRotatingCredentialsProvider(
                reporting: reporting,
                dataRetriever: dataRetriever)
        } catch {
            reporting.logger.error("Retrieving rotating credentials rotation failed: '\(error)'")
            
            return nil
        }
        
        return rotatingCredentialsProvider
    }
    
    private static func createRotatingCredentialsProvider<InvocationReportingType: HTTPClientCoreInvocationReporting>(
        reporting: InvocationReportingType,
        dataRetriever: @escaping () throws -> Data) throws
        -> StoppableCredentialsProvider {
        let credentialsRetriever = FromDataExpiringCredentialsRetriever(
            dataRetriever: dataRetriever)
            
        let awsContainerRotatingCredentialsProvider =
            try AwsContainerRotatingCredentialsProvider(
                expiringCredentialsRetriever: credentialsRetriever)
        
        awsContainerRotatingCredentialsProvider.start(
            roleSessionName: nil,
            reporting: reporting)
        
        reporting.logger.debug("Rotating credentials retrieved from environment.")
        
        // return the credentials
        return awsContainerRotatingCredentialsProvider
    }
    
    internal struct FromDataExpiringCredentialsRetriever: ExpiringCredentialsRetriever {
        let dataRetriever: () throws -> Data
        
        func close() {
            // nothing to do
        }
        
        func wait() {
            // nothing to do
        }
        
        func get() throws -> ExpiringCredentials {
            return try ExpiringCredentials.getCurrentCredentials(
                    dataRetriever: dataRetriever)
        }
    }
}
