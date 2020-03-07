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
//  BasicChannelInboundHandler.swift
//  SmokeAWSCredentials
//
import Foundation
import NIO
import NIOHTTP1
import Logging
import SmokeHTTPClient
import SmokeAWSCore
import NIOFoundationCompat

enum BasicHttpChannelError: Error {
    case invalidEndpoint(String)
    case badResponse(String)
    case errorResponse(UInt, String?)
    case noResponse
}

/**
 A basic ChannelInboundHandler for contacting an endpoint and
 returning the response as a Data instance.
 */
final class BasicChannelInboundHandler<InvocationReportingType: SmokeAWSInvocationReporting>: ChannelInboundHandler {
    public typealias InboundIn = HTTPClientResponsePart
    public typealias OutboundOut = HTTPClientRequestPart
    
    /// The endpoint path to request a response from.
    private let endpointPath: String
    private let endpointHostName: String
    private let reporting: InvocationReportingType
    
    /// The http head of the response received
    private var responseHead: HTTPResponseHead?
    /// The body data previously received.
    public var partialBody: Data?
    
    init(endpointHostName: String, endpointPath: String,
         reporting: InvocationReportingType) {
        self.endpointHostName = endpointHostName
        self.endpointPath = endpointPath
        self.reporting = reporting
    }
    
    static func call(endpointHostName: String,
                     endpointPath: String,
                     reporting: InvocationReportingType,
                     eventLoopProvider: HTTPClient.EventLoopProvider,
                     endpointPort: Int = 80
                     ) throws -> Data? {
        let handler = BasicChannelInboundHandler(endpointHostName: endpointHostName,
                                                 endpointPath: endpointPath,
                                                 reporting: reporting)
        
        let eventLoopGroup: EventLoopGroup
            
        switch eventLoopProvider {
        case .spawnNewThreads:
            eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        case .use(let existingEventLoopGroup):
            eventLoopGroup = existingEventLoopGroup
        }
        
        defer {
            if case .spawnNewThreads = eventLoopProvider {
                // shut down the event loop group when we are done
                // (as this function will block until the request is complete)
                do {
                    try eventLoopGroup.syncShutdownGracefully()
                } catch {
                    reporting.logger.debug("Unable to shut down event loop group: \(error)")
                }
            }
        }
        
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().flatMap {
                    channel.pipeline.addHandler(handler)
                }
            }
        
        let channel = try bootstrap.connect(host: endpointHostName, port: endpointPort).wait()
        
        // wait until the channel has been closed
        try channel.closeFuture.wait()
        
        // retrieve the response from the handler
        return try handler.getResponse()
    }
    
    /**
     Called when data has been received from the channel.
     */
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let responsePart = self.unwrapInboundIn(data)
        
        switch responsePart {
        // This is the response head
        case .head(let response):
            reporting.logger.debug("Response head received.")
            responseHead = response
        // This is part of the response body
        case .body(var byteBuffer):
            let byteBufferSize = byteBuffer.readableBytes
            let newData = byteBuffer.readData(length: byteBufferSize)
            
            if var newPartialBody = partialBody,
                let newData = newData {
                    newPartialBody += newData
                    partialBody = newPartialBody
            } else if let newData = newData {
                partialBody = newData
            }
            
            reporting.logger.debug("Response body part of \(byteBufferSize) bytes received.")
        // This is the response end
        case .end:
            reporting.logger.debug("Response end received.")
            // the head and all possible body parts have been received,
            // handle this response
            context.close(promise: nil)
        }
    }
    
    func channelReadComplete(context: ChannelHandlerContext) {
        reporting.logger.debug("channelReadComplete")
    }
    
    /*
     Gets the response from the handler
     */
    public func getResponse() throws -> Data? {
        reporting.logger.debug("Handling response body with \(partialBody?.count ?? 0) size.")
        
        // ensure the response head from received
        guard let responseHead = responseHead else {
            throw BasicHttpChannelError.badResponse("Response head was not received")
        }
        
        // if the response status is ok
        if case .ok = responseHead.status {
            // return the response data (potentially empty)
            return partialBody
        }
        
        let bodyAsString: String?
        if let responseBodyData = partialBody {
            bodyAsString = String(data: responseBodyData, encoding: .utf8)
        } else {
            bodyAsString = nil
        }
        
        throw BasicHttpChannelError.errorResponse(responseHead.status.code, bodyAsString)
    }
    
    /**
     Called when notifying about a connection error.
     */
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        reporting.logger.debug("Error received from HTTP connection: \(String(describing: error))")
        
        // close the channel
        context.close(promise: nil)
    }
    
    /**
     Called when the channel becomes active.
     */
    public func channelActive(context: ChannelHandlerContext) {
        reporting.logger.debug("channelActive")
        let headers = [("User-Agent", "SmokeAWSCredentials"),
                       ("Content-Length", "0"),
                       ("Host", endpointHostName),
                       ("Accept", "*/*")]
        
        // Create the request head
        var httpRequestHead = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1),
                                              method: .GET, uri: endpointPath)
        httpRequestHead.headers = HTTPHeaders(headers)
        
        // Send the request on the channel.
        context.write(self.wrapOutboundOut(.head(httpRequestHead)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}
