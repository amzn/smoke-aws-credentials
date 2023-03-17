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
import SmokeHTTPClient
import SmokeAWSCore
import Logging

internal extension NSLocking {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        self.lock()
        defer {
            self.unlock()
        }
        
        return try body()
    }
}

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
    func shutdown() async throws
    
    /**
     Retrieves a new instance of `ExpiringCredentials`.
     */
    @available(swift, deprecated: 3.0, message: "Use getCredentials on the ExpiringCredentialsRetrieverV2 protocol")
    func get() throws -> ExpiringCredentials
}

public extension ExpiringCredentialsRetriever {
    @available(swift, deprecated: 3.0, message: "To avoid a breaking change, by default syncShutdown() delegates to the implementation of close()")
    func syncShutdown() throws {
        try close()
    }
    
    func shutdown() async throws {
        fatalError("`shutdown() async throws` needs to be implemented on `ExpiringCredentialsRetriever` conforming type to allow for async shutdown.")
    }
}

/**
 Class that manages the rotating credentials.
 */
@available(*, deprecated, renamed: "AwsRotatingCredentialsProviderV2")
public class AwsRotatingCredentialsProvider: StoppableCredentialsProvider {
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
    var currentWorker: (() -> ())?
    let completedSemaphore = DispatchSemaphore(value: 0)
    var statusLock: NSLock = NSLock()
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
    }
    
    deinit {
        try? stop()
        wait()
    }
    
    /**
     Schedules credentials rotation to begin.
     */
    public func start<InvocationReportingType: HTTPClientCoreInvocationReporting>(
            roleSessionName: String?,
            reporting: InvocationReportingType) {
        guard case .initialized = status else {
            // if this instance isn't in the initialized state, do nothing
            return
        }
        
        // only actually need to start updating credentials if the
        // initial ones expire
        if let expiration = expiringCredentials.expiration {
            scheduleUpdateCredentials(beforeExpiration: expiration,
                                      roleSessionName: roleSessionName,
                                      reporting: reporting)
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
            try await expiringCredentialsRetriever.shutdown()
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
        
        completedSemaphore.wait()
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
    
    internal func scheduleUpdateCredentials<InvocationReportingType: HTTPClientCoreInvocationReporting>(
            beforeExpiration expiration: Date,
            roleSessionName: String?,
            reporting: InvocationReportingType) {
        // create a deadline 5 minutes before the expiration
        let timeInterval = (expiration - expirationBufferSeconds).timeIntervalSinceNow
        let timeInternalInMinutes = timeInterval / 60
        
        let minutes: Int = Int(timeInternalInMinutes) % 60
        let hours: Int = Int(timeInternalInMinutes) / 60
        
        let deadline = DispatchTime.now() + .seconds(Int(timeInterval))
        
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
            "\(logEntryPrefix) updated; rotation scheduled in \(hours) hours, \(minutes) minutes.")
        scheduler.asyncAfter(deadline: deadline, qos: .unspecified,
                             flags: [], execute: newWorker)
        
        self.statusLock.withLock {
            self.status = .running
            self.currentWorker = newWorker
        }
    }
}
