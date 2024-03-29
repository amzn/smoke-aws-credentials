// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
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

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

internal protocol AsyncAfterScheduler {
    func asyncAfter(deadline: DispatchTime, qos: DispatchQoS,
                    flags: DispatchWorkItemFlags,
                    execute work: @escaping @convention(block) () -> Void)
}

extension DispatchQueue: AsyncAfterScheduler {}

/**
 A protocol that retrieves `ExpiringCredentials` and that is closable.
 */
public protocol ExpiringCredentialsRetriever {
    /**
     Gracefully shuts down this retriever. This function is idempotent and
     will handle being called multiple times. Will block until shutdown is complete.
     */
    func syncShutdown() throws

    @available(*, deprecated, renamed: "syncShutdown")
    func close() throws

    /**
     Gracefully shuts down this retriever. This function is idempotent and
     will handle being called multiple times. Will return when shutdown is complete.
     */
    #if (os(Linux) && compiler(>=5.5)) || (!os(Linux) && compiler(>=5.5.2)) && canImport(_Concurrency)
        func shutdown() async throws
    #endif

    /**
     Retrieves a new instance of `ExpiringCredentials`.
     */
    func get() throws -> ExpiringCredentials
}

public extension ExpiringCredentialsRetriever {
    @available(swift, deprecated: 3.0, message: "To avoid a breaking change, by default syncShutdown() delegates to the implementation of close()")
    func syncShutdown() throws {
        try close()
    }

    #if (os(Linux) && compiler(>=5.5)) || (!os(Linux) && compiler(>=5.5.2)) && canImport(_Concurrency)
        func shutdown() async throws {
            fatalError("`shutdown() async throws` needs to be implemented on `ExpiringCredentialsRetriever` conforming type to allow for async shutdown.")
        }
    #endif
}

public protocol ExpiringCredentialsAsyncRetriever: ExpiringCredentialsRetriever {
    /**
     Retrieves a new instance of `ExpiringCredentials`.
     */
    func getCredentials() async throws -> ExpiringCredentials
}

/**
 Class that manages the rotating credentials.
 */
public class AwsRotatingCredentialsProvider: StoppableCredentialsProvider {
    public var credentials: Credentials {
        // the provider returns a copy of the current
        // credentials which is used within a request.
        // The provider is then free to rotate credentials
        // without the risk of rotation causing inconsistent
        // credentials to be used across a request.
        return self.expiringCredentials
    }

    private var expiringCredentials: ExpiringCredentials
    static let queue = DispatchQueue(label: "com.amazon.SmokeAWSCredentials.AwsRotatingCredentialsProvider")

    let expirationBufferSeconds = 300.0 // 5 minutes
    let validCredentialsRetrySeconds = 60.0 // 1 minute
    let invalidCredentialsRetrySeconds = 3600.0 // 1 hour

    public enum Status {
        case initialized
        case running
        case shuttingDown
        case stopped
    }

    public var status: Status
    var currentWorker: (() -> Void)?
    let completedSemaphore = DispatchSemaphore(value: 0)
    var statusMutex: pthread_mutex_t
    let expiringCredentialsRetriever: ExpiringCredentialsRetriever
    let scheduler: AsyncAfterScheduler

    /**
     Initializer that accepts the initial ExpiringCredentials instance for this provider.

     - Parameters:
        - expiringCredentialsRetriever: retriever of expiring credentials.
     */
    public convenience init(expiringCredentialsRetriever: ExpiringCredentialsRetriever) throws {
        try self.init(expiringCredentialsRetriever: expiringCredentialsRetriever,
                      scheduler: AwsRotatingCredentialsProvider.queue)
    }

    internal init(expiringCredentialsRetriever: ExpiringCredentialsRetriever,
                  scheduler: AsyncAfterScheduler) throws {
        self.expiringCredentials = try expiringCredentialsRetriever.get()
        self.currentWorker = nil
        self.expiringCredentialsRetriever = expiringCredentialsRetriever
        self.scheduler = scheduler
        self.status = .initialized
        var newMutux = pthread_mutex_t()

        var attr = pthread_mutexattr_t()
        guard pthread_mutexattr_init(&attr) == 0 else {
            preconditionFailure()
        }

        pthread_mutexattr_settype(&attr, Int32(PTHREAD_MUTEX_NORMAL))
        guard pthread_mutex_init(&newMutux, &attr) == 0 else {
            preconditionFailure()
        }
        pthread_mutexattr_destroy(&attr)

        self.statusMutex = newMutux
    }

    deinit {
        try? stop()
        wait()
    }

    /**
     Schedules credentials rotation to begin.
     */
    public func start<InvocationReportingType: HTTPClientCoreInvocationReporting>(roleSessionName: String?,
                                                                                  reporting: InvocationReportingType) {
        guard case .initialized = self.status else {
            // if this instance isn't in the initialized state, do nothing
            return
        }

        // only actually need to start updating credentials if the
        // initial ones expire
        if let expiration = expiringCredentials.expiration {
            self.scheduleUpdateCredentials(beforeExpiration: expiration,
                                           roleSessionName: roleSessionName,
                                           reporting: reporting)
        }
    }

    /**
     Gracefully shuts down credentials rotation, letting any ongoing work complete..
     */
    public func stop() throws {
        pthread_mutex_lock(&self.statusMutex)
        defer { pthread_mutex_unlock(&statusMutex) }

        // if there is currently a worker to shutdown
        switch self.status {
            case .initialized:
                // no worker ever started, can just go straight to stopped
                self.status = .stopped
                try self.expiringCredentialsRetriever.syncShutdown()
                self.completedSemaphore.signal()
            case .running:
                self.status = .shuttingDown
                try self.expiringCredentialsRetriever.syncShutdown()
            default:
                // nothing to do
                break
        }
    }

    #if (os(Linux) && compiler(>=5.5)) || (!os(Linux) && compiler(>=5.5.2)) && canImport(_Concurrency)
        public func shutdown() async throws {
            pthread_mutex_lock(&self.statusMutex)
            defer { pthread_mutex_unlock(&statusMutex) }

            // if there is currently a worker to shutdown
            switch self.status {
                case .initialized:
                    // no worker ever started, can just go straight to stopped
                    self.status = .stopped
                    try await self.expiringCredentialsRetriever.shutdown()
                    self.completedSemaphore.signal()
                case .running:
                    self.status = .shuttingDown
                    try await self.expiringCredentialsRetriever.shutdown()
                default:
                    // nothing to do
                    break
            }
        }
    #endif

    private func verifyWorkerNotStopped() -> Bool {
        pthread_mutex_lock(&self.statusMutex)
        defer { pthread_mutex_unlock(&statusMutex) }

        guard case .stopped = self.status else {
            return false
        }

        return true
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
        pthread_mutex_lock(&self.statusMutex)
        defer { pthread_mutex_unlock(&statusMutex) }

        guard case .running = self.status else {
            self.status = .stopped
            self.completedSemaphore.signal()
            return false
        }

        return true
    }

    internal func scheduleUpdateCredentials<InvocationReportingType: HTTPClientCoreInvocationReporting>(beforeExpiration expiration: Date,
                                                                                                        roleSessionName: String?,
                                                                                                        reporting: InvocationReportingType) {
        // create a deadline 5 minutes before the expiration
        let waitDurationInSeconds = (expiration - self.expirationBufferSeconds).timeIntervalSinceNow
        let waitDurationInMinutes = waitDurationInSeconds / 60

        let wholeNumberOfHours = Int(waitDurationInMinutes) / 60
        // the total number of minutes minus the number of minutes
        // that can be expressed in a whole number of hours.
        // Can also be expressed as: let overflowMinutes = waitDurationInMinutes - (wholeNumberOfHours * 60)
        let overflowMinutes = Int(waitDurationInMinutes) % 60

        let deadline = DispatchTime.now() + .seconds(Int(waitDurationInSeconds))

        let logEntryPrefix: String
        if let roleSessionName = roleSessionName {
            logEntryPrefix = "Credentials for session '\(roleSessionName)'"
        } else {
            logEntryPrefix = "Credentials"
        }

        // create a new worker that will update the credentials
        let newWorker = { [unowned self] in
            guard self.verifyWorkerNotCancelled() else {
                return
            }

            reporting.logger.trace("\(logEntryPrefix) about to expire; rotating.")

            let expiration: Date?
            do {
                let expiringCredentials = try self.expiringCredentialsRetriever.get()

                self.expiringCredentials = expiringCredentials

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

                    reporting.logger.warning(
                        "\(logPrefix) Credentials still valid. Attempting credentials refresh in 1 minute.")
                } else {
                    // at this point, we have tried multiple times to get new credentials
                    // something is quite wrong; try again in the future but at
                    // a reduced frequency
                    retryDuration = self.invalidCredentialsRetrySeconds

                    reporting.logger.error(
                        "\(logPrefix) Credentials no longer valid. Attempting credentials refresh in 1 hour.")
                }

                expiration = Date(timeIntervalSinceNow: retryDuration)
            }

            // if there is an expiry, schedule a rotation
            if let expiration = expiration {
                self.scheduleUpdateCredentials(beforeExpiration: expiration,
                                               roleSessionName: roleSessionName,
                                               reporting: reporting)
            }
        }

        reporting.logger.trace(
            "\(logEntryPrefix) updated; rotation scheduled in \(wholeNumberOfHours) hours, \(overflowMinutes) minutes.")
        self.scheduler.asyncAfter(deadline: deadline, qos: .unspecified,
                                  flags: [], execute: newWorker)

        pthread_mutex_lock(&self.statusMutex)
        defer { pthread_mutex_unlock(&statusMutex) }

        self.status = .running
        self.currentWorker = newWorker
    }
}
