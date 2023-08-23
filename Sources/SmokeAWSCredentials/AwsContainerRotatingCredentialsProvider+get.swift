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
//  AwsContainerRotatingCredentials+get.swift
//  SmokeAWSCredentials
//

import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import SmokeAWSCore
import SmokeAWSHttp
import SmokeHTTPClient

private let maximumBodySize = 1024 * 1024 // 1 MB

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
    @available(swift, deprecated: 3.0, message: "Use async version. traceContext no longer required.")
    static func get<TraceContextType: InvocationTraceContext>(fromEnvironment environment: [String: String] = ProcessInfo.processInfo.environment,
                                                              logger: Logging.Logger = Logger(label: "com.amazon.SmokeAWSCredentials"),
                                                              traceContext _: TraceContextType,
                                                              eventLoopProvider: HTTPClient.EventLoopGroupProvider = .singleton)
    -> StoppableCredentialsProvider? {
        return self.get(fromEnvironment: environment,
                        logger: logger,
                        eventLoopProvider: eventLoopProvider)
    }

    /**
     Static function that retrieves credentials provider from the specified environment -
     either rotating credentials retrieved from an endpoint specified under the
     AWS_CONTAINER_CREDENTIALS_RELATIVE_URI key or if that key isn't present,
     static credentials under the AWS_SECRET_ACCESS_KEY and AWS_ACCESS_KEY_ID keys.
     */
    @available(swift, deprecated: 3.0, message: "Use async version")
    static func get(fromEnvironment environment: [String: String] = ProcessInfo.processInfo.environment,
                    logger: Logging.Logger = Logger(label: "com.amazon.SmokeAWSCredentials"),
                    eventLoopProvider: HTTPClient.EventLoopGroupProvider = .singleton)
    -> StoppableCredentialsProvider? {
        var credentialsLogger = logger
        credentialsLogger[metadataKey: "credentials.source"] = "environment"

        var credentialsProvider: StoppableCredentialsProvider?
        if let credentialsRetriever = getRotatingCredentialsRetriever(fromEnvironment: environment,
                                                                      logger: credentialsLogger,
                                                                      eventLoopProvider: eventLoopProvider,
                                                                      dataRetrieverOverride: nil) {
            credentialsProvider = credentialsRetriever.asAwsRotatingCredentialsProviderV2(logger: credentialsLogger)
        }

        if credentialsProvider == nil,
           let staticCredentials = getStaticCredentialsProvider(fromEnvironment: environment,
                                                                logger: credentialsLogger) {
            credentialsProvider = staticCredentials
        }

        #if DEBUG
            if credentialsProvider == nil,
               let credentialsRetriever = getDevRotatingCredentialsRetriever(fromEnvironment: environment,
                                                                             logger: credentialsLogger) {
                credentialsProvider = credentialsRetriever.asAwsRotatingCredentialsProviderV2(logger: credentialsLogger)
            }
        #endif

        return credentialsProvider
    }

    static func get(fromEnvironment environment: [String: String] = ProcessInfo.processInfo.environment,
                    logger: Logging.Logger = Logger(label: "com.amazon.SmokeAWSCredentials"),
                    eventLoopProvider: HTTPClient.EventLoopGroupProvider = .singleton) async
    -> StoppableCredentialsProvider? {
        return await self.get(fromEnvironment: environment,
                              logger: logger,
                              dataRetrieverOverride: nil,
                              eventLoopProvider: eventLoopProvider)
    }

    // Testing entry point
    internal static func get(fromEnvironment environment: [String: String] = ProcessInfo.processInfo.environment,
                             logger: Logging.Logger = Logger(label: "com.amazon.SmokeAWSCredentials"),
                             dataRetrieverOverride: (() throws -> Data)?,
                             eventLoopProvider: HTTPClient.EventLoopGroupProvider = .singleton) async
    -> StoppableCredentialsProvider? {
        var credentialsLogger = logger
        credentialsLogger[metadataKey: "credentials.source"] = "environment"

        var credentialsProvider: StoppableCredentialsProvider?
        if let credentialsRetriever = getRotatingCredentialsRetriever(fromEnvironment: environment,
                                                                      logger: credentialsLogger,
                                                                      eventLoopProvider: eventLoopProvider,
                                                                      dataRetrieverOverride: dataRetrieverOverride) {
            credentialsProvider = await credentialsRetriever.asAwsRotatingCredentialsProviderV2(logger: credentialsLogger)
        }

        if credentialsProvider == nil,
           let staticCredentials = getStaticCredentialsProvider(fromEnvironment: environment,
                                                                logger: credentialsLogger) {
            credentialsProvider = staticCredentials
        }

        #if DEBUG
            if credentialsProvider == nil,
               let credentialsRetriever = getDevRotatingCredentialsRetriever(fromEnvironment: environment,
                                                                             logger: credentialsLogger) {
                credentialsProvider = await credentialsRetriever.asAwsRotatingCredentialsProviderV2(logger: credentialsLogger)
            }
        #endif

        return credentialsProvider
    }

    private static func getStaticCredentialsProvider(fromEnvironment environment: [String: String],
                                                     logger: Logger)
    -> StoppableCredentialsProvider? {
        // get the values of the environment variables
        let awsAccessKeyId = environment["AWS_ACCESS_KEY_ID"]
        let awsSecretAccessKey = environment["AWS_SECRET_ACCESS_KEY"]
        let sessionToken = environment["AWS_SESSION_TOKEN"]

        guard let secretAccessKey = awsSecretAccessKey, let accessKeyId = awsAccessKeyId else {
            let logMessage = "'AWS_ACCESS_KEY_ID' and 'AWS_SESSION_TOKEN' environment variables not"
                + "specified. Static credentials not available."
            logger.trace("\(logMessage)")

            return nil
        }

        logger.trace("Static credentials retrieved from environment.")

        // return these credentials
        return SmokeAWSCore.StaticCredentials(accessKeyId: accessKeyId,
                                              secretAccessKey: secretAccessKey,
                                              sessionToken: sessionToken)
    }

    #if DEBUG
        private static func getDevRotatingCredentialsRetriever(fromEnvironment environment: [String: String],
                                                               logger: Logger)
        -> FromDataExpiringCredentialsRetriever? {
            // get the values of the environment variables
            let devCredentialsIamRoleArn = environment["DEV_CREDENTIALS_IAM_ROLE_ARN"]

            guard let iamRoleArn = devCredentialsIamRoleArn else {
                let logMessage = "'DEV_CREDENTIALS_IAM_ROLE_ARN' environment variable not specified."
                    + " Dev rotating credentials not available."

                logger.trace("\(logMessage)")

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
                task.arguments = [
                    "/usr/local/bin/get-credentials.sh",
                    "-r",
                    iamRoleArn,
                    "-d",
                    "900"
                ]
                task.standardOutput = outputPipe
                #if os(Linux) && swift(>=5.0)
                    try task.run()
                #else
                    task.launch()
                #endif
                task.waitUntilExit()

                return outputPipe.fileHandleForReading.availableData
            }

            return FromDataExpiringCredentialsRetriever(
                dataRetriever: dataRetriever,
                asyncDataRetriever: dataRetriever)
        }
    #endif

    private static func getDataRetriever(credentialsPath: String,
                                         logger: Logger,
                                         eventLoopProvider: HTTPClient.EventLoopGroupProvider) -> () throws -> Data {
        func dataRetriever() throws -> Data {
            let infix: String
            if let credentialsPrefix = credentialsPath.first, credentialsPrefix != "/" {
                infix = "/"
            } else {
                infix = ""
            }

            let completedSemaphore = DispatchSemaphore(value: 0)
            var result: Result<HTTPClient.Response, Error>?
            let endpoint = "http://\(credentialsHost)\(infix)\(credentialsPath)"

            let headers = [
                ("User-Agent", "SmokeAWSCredentials"),
                ("Content-Length", "0"),
                ("Host", credentialsHost),
                ("Accept", "*/*")
            ]

            logger.trace("Retrieving environment credentials from endpoint: \(endpoint)")

            let request = try HTTPClient.Request(url: endpoint, method: .GET, headers: HTTPHeaders(headers))

            let httpClient = HTTPClient(eventLoopGroupProvider: eventLoopProvider)
            httpClient.execute(request: request).whenComplete { returnedResult in
                result = returnedResult
                completedSemaphore.signal()
            }
            defer {
                try? httpClient.syncShutdown()
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

        return dataRetriever
    }

    private static func getAsyncDataRetriever(credentialsPath: String,
                                              logger: Logger,
                                              eventLoopProvider: HTTPClient.EventLoopGroupProvider) -> () async throws -> Data {
        func asyncDataRetriever() async throws -> Data {
            let infix: String
            if let credentialsPrefix = credentialsPath.first, credentialsPrefix != "/" {
                infix = "/"
            } else {
                infix = ""
            }

            let endpoint = "http://\(credentialsHost)\(infix)\(credentialsPath)"

            let headers = [
                ("User-Agent", "SmokeAWSCredentials"),
                ("Content-Length", "0"),
                ("Host", credentialsHost),
                ("Accept", "*/*")
            ]

            logger.trace("Retrieving environment credentials from endpoint: \(endpoint)")

            let httpClient = HTTPClient(eventLoopGroupProvider: eventLoopProvider)
            defer {
                try? httpClient.syncShutdown()
            }

            var request = HTTPClientRequest(url: endpoint)
            request.method = .GET
            request.headers = HTTPHeaders(headers)
            let response = try await httpClient.execute(request, deadline: NIODeadline.distantFuture)

            var byteBuffer = try await response.body.collect(upTo: maximumBodySize)
            let byteBufferSize = byteBuffer.readableBytes
            let bodyAsData = byteBuffer.readData(length: byteBufferSize) ?? Data()

            // if the response status is ok
            if case .ok = response.status {
                return bodyAsData
            }

            let bodyAsString = String(data: bodyAsData, encoding: .utf8)

            throw CredentialsHTTPError.errorResponse(response.status.code, bodyAsString)
        }

        return asyncDataRetriever
    }

    private static func getRotatingCredentialsRetriever(fromEnvironment environment: [String: String],
                                                        logger: Logger,
                                                        eventLoopProvider: HTTPClient.EventLoopGroupProvider,
                                                        dataRetrieverOverride: (() throws -> Data)?)
    -> FromDataExpiringCredentialsRetriever? {
        // get the values of the environment variables
        let awsContainerCredentialsRelativeUri = environment["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"]

        guard let credentialsPath = awsContainerCredentialsRelativeUri else {
            let logMessage = "'AWS_CONTAINER_CREDENTIALS_RELATIVE_URI' environment variable not specified."
                + " Rotating credentials not available."

            logger.trace("\(logMessage)")

            return nil
        }

        let dataRetriever: () throws -> Data
        let asyncDataRetriever: () async throws -> Data
        if let dataRetrieverOverride = dataRetrieverOverride {
            dataRetriever = dataRetrieverOverride
            asyncDataRetriever = dataRetrieverOverride
        } else {
            dataRetriever = self.getDataRetriever(credentialsPath: credentialsPath, logger: logger, eventLoopProvider: eventLoopProvider)
            asyncDataRetriever = self.getAsyncDataRetriever(credentialsPath: credentialsPath, logger: logger, eventLoopProvider: eventLoopProvider)
        }

        return FromDataExpiringCredentialsRetriever(
            dataRetriever: dataRetrieverOverride ?? dataRetriever,
            asyncDataRetriever: dataRetrieverOverride ?? asyncDataRetriever)
    }

    internal struct FromDataExpiringCredentialsRetriever: ExpiringCredentialsRetriever {
        let dataRetriever: () throws -> Data
        let asyncDataRetriever: () async throws -> Data

        func close() {
            // nothing to do
        }

        #if (os(Linux) && compiler(>=5.5)) || (!os(Linux) && compiler(>=5.5.2)) && canImport(_Concurrency)
            func shutdown() async throws {
                // nothing to do
            }
        #endif

        func wait() {
            // nothing to do
        }

        func get() throws -> ExpiringCredentials {
            return try ExpiringCredentials.getCurrentCredentials(
                dataRetriever: self.dataRetriever)
        }

        @available(swift, deprecated: 3.0, message: "Use async version")
        func asAwsRotatingCredentialsProviderV2(logger: Logger) -> AwsRotatingCredentialsProviderV2? {
            let rotatingCredentialsProvider: AwsRotatingCredentialsProviderV2
            do {
                rotatingCredentialsProvider = try AwsRotatingCredentialsProviderV2(
                    expiringCredentialsRetriever: self,
                    roleSessionName: nil,
                    logger: logger)
            } catch {
                logger.error("Retrieving dev rotating credentials rotation failed: '\(error)'")

                return nil
            }

            return rotatingCredentialsProvider
        }

        func asAwsRotatingCredentialsProviderV2(logger: Logger) async -> AwsRotatingCredentialsProviderV2? {
            let rotatingCredentialsProvider: AwsRotatingCredentialsProviderV2
            do {
                rotatingCredentialsProvider = try await AwsRotatingCredentialsProviderV2(
                    expiringCredentialsRetriever: self,
                    roleSessionName: nil,
                    logger: logger)
            } catch {
                logger.error("Retrieving dev rotating credentials rotation failed: '\(error)'")

                return nil
            }

            return rotatingCredentialsProvider
        }
    }
}

extension AwsContainerRotatingCredentialsProvider.FromDataExpiringCredentialsRetriever: ExpiringCredentialsAsyncRetriever {
    func getCredentials() async throws -> ExpiringCredentials {
        return try await ExpiringCredentials.getCurrentCredentials(
            dataRetriever: self.asyncDataRetriever)
    }
}
