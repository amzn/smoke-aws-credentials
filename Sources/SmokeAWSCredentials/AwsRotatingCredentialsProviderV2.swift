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
//  AwsRotatingCredentials.swift
//  SmokeAWSCredentials
//

import Foundation
import Logging
import SmokeAWSCore
import SmokeHTTPClient

private let secondsToNanoSeconds: UInt64 = 1_000_000_000

internal extension NSLocking {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        self.lock()
        defer {
            self.unlock()
        }

        return try body()
    }
}

/**
 Class that manages the rotating credentials.
 */
public class AwsRotatingCredentialsProviderV2: StoppableCredentialsProvider {
    public var credentials: Credentials {
        // the provider returns a copy of the current
        // credentials which is used within a request.
        // The provider is then free to rotate credentials
        // without the risk of rotation causing inconsistent
        // credentials to be used across a request.
        return self.statusLock.withLock {
            return expiringCredentials
        }
    }

    private var expiringCredentials: ExpiringCredentials

    let expirationBufferSeconds = 300.0 // 5 minutes
    let validCredentialsRetrySeconds = 60.0 // 1 minute
    let invalidCredentialsRetrySeconds = 3600.0 // 1 hour

    let roleSessionName: String?
    let logger: Logger

    public enum Status {
        case initialized
        case running
        case shuttingDown
        case stopped
    }

    public var status: Status
    let completedSemaphore = DispatchSemaphore(value: 0)
    var statusLock: NSLock = .init()
    let expiringCredentialsRetriever: ExpiringCredentialsAsyncRetriever

    /**
     Initializer that accepts the initial ExpiringCredentials instance for this provider.

     - Parameters:
        - expiringCredentialsRetriever: retriever of expiring credentials.
     */
    @available(swift, deprecated: 3.0, message: "Migrate to async constructor")
    public init(expiringCredentialsRetriever: ExpiringCredentialsAsyncRetriever,
                roleSessionName: String?,
                logger: Logger) throws {
        self.expiringCredentials = try expiringCredentialsRetriever.get()
        self.expiringCredentialsRetriever = expiringCredentialsRetriever
        self.roleSessionName = roleSessionName
        self.logger = logger
        self.status = .initialized
    }

    public init(expiringCredentialsRetriever: ExpiringCredentialsAsyncRetriever,
                roleSessionName: String?,
                logger: Logger) async throws {
        self.expiringCredentials = try await expiringCredentialsRetriever.getCredentials()
        self.expiringCredentialsRetriever = expiringCredentialsRetriever
        self.roleSessionName = roleSessionName
        self.logger = logger
        self.status = .initialized
    }

    deinit {
        try? stop()
        wait()
    }

    /**
     Schedules credentials rotation to begin.
     */
    public func start() {
        self.statusLock.withLock {
            guard case .initialized = status else {
                // if this instance isn't in the initialized state, do nothing
                return
            }

            // only actually need to start updating credentials if the
            // initial ones expire
            if self.expiringCredentials.expiration != nil {
                Task(priority: .medium) {
                    await run()
                }

                self.status = .running
            }
        }
    }

    /**
     Gracefully shuts down credentials rotation, letting any ongoing work complete..
     */
    public func stop() throws {
        try self.statusLock.withLock {
            // if there is currently a worker to shutdown
            switch status {
                case .initialized:
                    // no worker ever started, can just go straight to stopped
                    status = .stopped
                    try expiringCredentialsRetriever.syncShutdown()
                    completedSemaphore.signal()
                case .running:
                    status = .shuttingDown
                    try expiringCredentialsRetriever.syncShutdown()
                default:
                    // nothing to do
                    break
            }
        }
    }

    public func shutdown() async throws {
        let isShutdown = self.statusLock.withLock { () -> Bool in
            // if there is currently a worker to shutdown
            switch status {
                case .initialized:
                    // no worker ever started, can just go straight to stopped
                    status = .stopped
                    completedSemaphore.signal()
                    return true
                case .running:
                    status = .shuttingDown
                    return true
                default:
                    // nothing to do
                    break
            }

            return false
        }

        if isShutdown {
            try await self.expiringCredentialsRetriever.shutdown()
        }
    }

    private func verifyWorkerNotStopped() -> Bool {
        return self.statusLock.withLock {
            guard case .stopped = status else {
                return false
            }

            return true
        }
    }

    /**
     Waits for the work to exit.
     If stop() is not called, this will block forever.
     */
    public func wait() {
        guard self.verifyWorkerNotStopped() else {
            return
        }

        self.completedSemaphore.wait()
    }

    private func verifyWorkerNotCancelled() -> Bool {
        return self.statusLock.withLock {
            guard case .running = status else {
                status = .stopped
                completedSemaphore.signal()
                return false
            }

            return true
        }
    }

    func run() async {
        var expiration: Date? = self.expiringCredentials.expiration

        while let currentExpiration = expiration {
            guard self.verifyWorkerNotCancelled() else {
                return
            }

            // create a deadline 5 minutes before the expiration
            let waitDurationInSeconds = (currentExpiration - self.expirationBufferSeconds).timeIntervalSinceNow
            let waitDurationInMinutes = waitDurationInSeconds / 60

            let wholeNumberOfHours = Int(waitDurationInMinutes) / 60
            // the total number of minutes minus the number of minutes
            // that can be expressed in a whole number of hours
            // Can also be expressed as: let overflowMinutes = waitDurationInMinutes - (wholeNumberOfHours * 60)
            let overflowMinutes = Int(waitDurationInMinutes) % 60

            let logEntryPrefix: String
            if let roleSessionName = self.roleSessionName {
                logEntryPrefix = "Credentials for session '\(roleSessionName)'"
            } else {
                logEntryPrefix = "Credentials"
            }

            self.logger.trace(
                "\(logEntryPrefix) updated; rotation scheduled in \(wholeNumberOfHours) hours, \(overflowMinutes) minutes.")
            do {
                try await Task.sleep(nanoseconds: UInt64(waitDurationInSeconds) * secondsToNanoSeconds)
            } catch {
                self.logger.error(
                    "\(logEntryPrefix) rotation stopped due to error \(error).")
            }

            expiration = await self.updateCredentials(roleSessionName: roleSessionName, logger: self.logger)
        }
    }

    private func updateCredentials(roleSessionName: String?,
                                   logger _: Logger) async
    -> Date? {
        let logEntryPrefix: String
        if let roleSessionName = roleSessionName {
            logEntryPrefix = "Credentials for session '\(roleSessionName)'"
        } else {
            logEntryPrefix = "Credentials"
        }

        self.logger.trace("\(logEntryPrefix) about to expire; rotating.")

        let expiration: Date?
        do {
            let expiringCredentials = try await self.expiringCredentialsRetriever.getCredentials()

            self.statusLock.withLock {
                self.expiringCredentials = expiringCredentials
            }

            expiration = expiringCredentials.expiration
        } catch {
            let timeIntervalSinceNow =
                self.expiringCredentials.expiration?.timeIntervalSinceNow ?? 0

            let retryDuration: Double
            let logPrefix = "\(logEntryPrefix) rotation failed."

            // if the expiry of the current credentials is still in the future
            if timeIntervalSinceNow > 0 {
                // try again relatively soon (still within the 5 minute credentials
                // expirary buffer) to get new credentials
                retryDuration = self.validCredentialsRetrySeconds

                self.logger.warning(
                    "\(logPrefix) Credentials still valid. Attempting credentials refresh in 1 minute.")
            } else {
                // at this point, we have tried multiple times to get new credentials
                // something is quite wrong; try again in the future but at
                // a reduced frequency
                retryDuration = self.invalidCredentialsRetrySeconds

                self.logger.error(
                    "\(logPrefix) Credentials no longer valid. Attempting credentials refresh in 1 hour.")
            }

            expiration = Date(timeIntervalSinceNow: retryDuration)
        }

        return expiration
    }
}
