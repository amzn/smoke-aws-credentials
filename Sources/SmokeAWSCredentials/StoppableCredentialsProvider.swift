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
//  StoppableCredentialsProvider.swift
//  SmokeAWSCredentials
//

import Foundation
import SmokeAWSCore

/**
 Extension protocol of the CredentialsProvider protocol that adds
 functions to stop and wait on background management of these
 credentials.
 */
public protocol StoppableCredentialsProvider: CredentialsProvider {
    /**
     Gracefully shuts down background management of these
     credentials. May block until ongoing work completes.
     */
    func syncShutdown() throws

    @available(*, deprecated, renamed: "syncShutdown")
    func stop() throws

    #if (os(Linux) && compiler(>=5.5)) || (!os(Linux) && compiler(>=5.5.2)) && canImport(_Concurrency)
        func shutdown() async throws
    #endif
}

public extension StoppableCredentialsProvider {
    @available(swift, deprecated: 3.0, message: "To avoid a breaking change, by default syncShutdown() delegates to the implementation of stop()")
    func syncShutdown() throws {
        try stop()
    }

    #if (os(Linux) && compiler(>=5.5)) || (!os(Linux) && compiler(>=5.5.2)) && canImport(_Concurrency)
        func shutdown() async throws {
            fatalError("`shutdown() async throws` needs to be implemented on `StoppableCredentialsProvider` conforming type to allow for async shutdown.")
        }
    #endif
}

/**
 Conform StaticCredentials to StoppableCredentialsProvider to allow
 StaticCredentials to be returned. Nothing actually needs to be stopped.
 */
extension SmokeAWSCore.StaticCredentials: StoppableCredentialsProvider {
    public func stop() throws {
        // nothing to do
    }

    #if (os(Linux) && compiler(>=5.5)) || (!os(Linux) && compiler(>=5.5.2)) && canImport(_Concurrency)
        public func shutdown() async throws {
            // nothing to do
        }
    #endif
}
