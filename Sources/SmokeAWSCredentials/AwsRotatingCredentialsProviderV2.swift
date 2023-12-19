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
//  AwsRotatingCredentialsV2.swift
//  SmokeAWSCredentials
//

import Foundation
import Logging
import AWSCore
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
 An actor that manages the current credentials. CurrentCredentials will attempt to always
 keep the credentials valid firstly by scheduling a background task and in the worst case
 fetching updated credentials when credentials are requested.
 */
private actor CurrentCredentials {
    private var state: State
    private let expiringCredentialsRetriever: ExpiringCredentialsAsyncRetriever
    
    // the task to schedule a background refresh
    private var backgroundRefreshTask: Task<Void, Never>?
    // the task to refresh the credentials in the background
    // this is held seperately to `state` so the existing credentials can continue to
    // be used until the background refresh is complete
    private var backgroundPendingCredentialsTask: Task<ExpiringCredentials, Swift.Error>?
    private let logger: Logger
    private let credentialsStreamContinuation: AsyncStream<ExpiringCredentials>.Continuation
    
    private enum State {
        case present(ExpiringCredentials)
        case pending(Task<ExpiringCredentials, Swift.Error>)
        case missing // the credentials have previously expired and new credentials have failed to be retrieved
    }
    
    private let expirationBufferSeconds: Double
    private let backgroundExpirationBufferSeconds: Double

    /**
     Initializes the actor.
     
     - Parameters:
        - credentials: the initial credentials
        - expiringCredentialsRetriever: used to retrieve refreshed credentials when required
        - backgroundLogger: the logger to use for background credential refreshes
        - credentialsStreamContinuation: the continuation for a stream of credential updates.
     */
    init(
        credentials: ExpiringCredentials,
        expiringCredentialsRetriever: ExpiringCredentialsAsyncRetriever,
        logger: Logger,
        credentialsStreamContinuation: AsyncStream<ExpiringCredentials>.Continuation,
        expirationBufferSeconds: Double,
        backgroundExpirationBufferSeconds: Double
    ) {
        self.state = .present(credentials)
        self.expiringCredentialsRetriever = expiringCredentialsRetriever
        self.logger = logger
        self.credentialsStreamContinuation = credentialsStreamContinuation
        self.expirationBufferSeconds = expirationBufferSeconds
        self.backgroundExpirationBufferSeconds = backgroundExpirationBufferSeconds
    }
    
    /**
     Starts a task to manage refreshing the current credentials just before they are about to expire.
     */
    func startBackgroundRefreshTaskIfRequired() {
        switch self.state {
        case .present(let presentValue):
            if let currentExpiration = presentValue.expiration {
                self.backgroundRefreshTask = scheduleRefreshBeforeExpiration(currentExpiration)
            }
        case .pending, .missing:
            // nothing to do
            break
        }
    }

    /**
     Gets the current credentials, ensuring that these credentials are always valid
     */
    func get(
        isBackgroundRefresh: Bool = false
    ) async throws -> AWSCore.Credentials {
        switch self.state {
        case .present(let presentValue):
            // if not within the buffer period and about to become expired
            if !isBackgroundRefresh, let expiration = presentValue.expiration, 
                  expiration > Date(timeIntervalSinceNow: self.expirationBufferSeconds) {
                // these credentials can be used
                self.logger.trace("Current credentials used. Current credentials do not expire until \(expiration.iso8601)")
                
                return presentValue
            } else if let backgroundPendingCredentialsTask = self.backgroundPendingCredentialsTask {
                self.logger.trace("Waiting on existing background credentials refresh")
                
                // if there is an-progress background refresh
                // normally we wouldn't wait on this task but the current credentials are now expired
                // so they can't be used
                return try await backgroundPendingCredentialsTask.value
            }
            
            if let expiration = presentValue.expiration {
                self.logger.trace("Replacing current credentials. Current credentials expiring at \(expiration.iso8601)")
            } else {
                self.logger.trace("Replacing current credentials.")
            }
        case .pending(let task):
            // There is a pending credentials refresh
            self.logger.trace("Waiting on existing credentials refresh")

            return try await task.value
        case .missing:
            self.logger.trace("Fetching new credentials.")
        }

        // get the task for this entry
        let task = self.handleGetFromRetriever(isBackgroundRefresh: isBackgroundRefresh)
        
        // if this is a background refresh, continue to use
        // the existing credentials until the refreshed credentials
        // are available (in other words don't hold up getting credentials
        // for a client while the background refresh is in progress)
        if !isBackgroundRefresh {
            // cancel any background refresh task
            backgroundRefreshTask?.cancel()
            backgroundRefreshTask = nil
            
            // update the entry
            // any concurrent credential gets will also wait for this task
            self.state = .pending(task)
        } else {
            self.backgroundPendingCredentialsTask = task
        }

        return try await task.value
    }
    
    func stop() async {
        self.backgroundRefreshTask?.cancel()
        self.backgroundPendingCredentialsTask?.cancel()
        
        do {
            try await self.expiringCredentialsRetriever.shutdown()
        } catch {
            self.logger.warning("ExpiringCredentialsRetriever failed to shutdown cleanly",
                                metadata: ["cause": "\(error)"])
        }
        
        switch self.state {
        case .pending(let task):
            task.cancel()
        case .present, .missing:
            // nothing to do
            break
        }
    }

    private func handleGetFromRetriever(isBackgroundRefresh: Bool) -> Task<ExpiringCredentials, Swift.Error> {
        Task.detached {
            let result: Result<ExpiringCredentials, Swift.Error>
            do {
                // wait for the value of the entry to be retrieved
                let value = try await self.expiringCredentialsRetriever.getCredentials()

                result = .success(value)
            } catch {
                result = .failure(error)
            }

            await self.addEntry(isBackgroundRefresh: isBackgroundRefresh, result: result)

            switch result {
                case .success(let newEntry):
                    return newEntry
                case .failure(let error):
                    throw error
            }
        }
    }

    private func addEntry(
        isBackgroundRefresh: Bool,
        result: Result<ExpiringCredentials, Swift.Error>
    ) {
        self.backgroundPendingCredentialsTask = nil
        
        guard case .success(let credentials) = result else {
            // we ignore the failure of a background refresh, now relying on a refresh initiated by a credentials get
            // if a refresh initiated by a credentials get fails, we potentially just don't have any valid credentials
            // set the state is `.missing` so any future credentials get can try again to refresh the credentials
            if !isBackgroundRefresh {
                self.state = .missing
            }
            return
        }
        
        self.credentialsStreamContinuation.yield(credentials)
        
        if let currentExpiration = credentials.expiration {
            // there are new credentials, schedule their refresh before they expire
            self.backgroundRefreshTask = scheduleRefreshBeforeExpiration(currentExpiration)
        }

        // update the entry
        self.state = .present(credentials)
    }
    
    // creates a task that will suspend until just before the current credentials expire
    // and then initiates a refresh of the current credentials
    private nonisolated func scheduleRefreshBeforeExpiration(_ currentExpiration: Date) -> Task<Void, Never> {
        return Task {
            // create a deadline 5 minutes before the expiration
            let waitDurationInSeconds = (currentExpiration - self.backgroundExpirationBufferSeconds).timeIntervalSinceNow
            let waitDurationInMinutes = waitDurationInSeconds / 60
            
            let wholeNumberOfHours = Int(waitDurationInMinutes) / 60
            // the total number of minutes minus the number of minutes
            // that can be expressed in a whole number of hours
            // Can also be expressed as: let overflowMinutes = waitDurationInMinutes - (wholeNumberOfHours * 60)
            let overflowMinutes = Int(waitDurationInMinutes) % 60
                     
            if waitDurationInSeconds > 0 {
                self.logger.trace(
                    "Credentials updated; rotation scheduled in \(wholeNumberOfHours) hours, \(overflowMinutes) minutes.")
                do {
                    try await Task.sleep(nanoseconds: UInt64(waitDurationInSeconds) * secondsToNanoSeconds)
                } catch is CancellationError {
                    self.logger.trace(
                        "Background credentials rotation cancelled.")
                    return
                } catch {
                    self.logger.error(
                        "Background credentials rotation failed due to error \(error).")
                    return
                }
            }
                        
            do {
                _ = try await self.get(isBackgroundRefresh: true)
            } catch is CancellationError {
                self.logger.trace(
                    "Background credentials rotation cancelled.")
                return
            } catch {
                self.logger.error(
                    "Background credentials rotation failed due to error \(error).")
                return
            }
            
            self.logger.trace(
                "Background credentials rotation completed.")
        }
    }
}

/**
 Class that manages the rotating credentials.
 */
public class AwsRotatingCredentialsProviderV2: StoppableCredentialsProvider, CredentialsProviderV2 {
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
        
    private let currentCredentials: CurrentCredentials
    // a stream of credentials updates that is used to ensure the `credentials` property required by the original
    // `CredentialsProvider` protocol returns the latest set of credentials. Credential instances can be placed into this
    // stream either due to a background refresh or initiated by a call to `getCredentials() async throws` that identified
    // expired credentials and refreshes them on demand
    private let credentialsStream: (stream: AsyncStream<ExpiringCredentials>, continuation: AsyncStream<ExpiringCredentials>.Continuation)

    public enum Status {
        case initialized
        case running
        case shuttingDown
        case stopped
    }

    public var status: Status
    let completedSemaphore = DispatchSemaphore(value: 0)
    var statusLock: NSLock = .init()

    /**
     Initializer that accepts the initial ExpiringCredentials instance for this provider.

     - Parameters:
        - expiringCredentialsRetriever: retriever of expiring credentials.
     */
    @available(swift, deprecated: 3.0, message: "Migrate to async constructor")
    public init(expiringCredentialsRetriever: ExpiringCredentialsAsyncRetriever,
                roleSessionName: String?,
                logger: Logger,
                expirationBufferSeconds: Double = 120.0, // 2 minutes
                backgroundExpirationBufferSeconds: Double = 300.0) throws { // 5 minutes
        self.expiringCredentials = try expiringCredentialsRetriever.get()
        self.status = .initialized
        
        self.credentialsStream = AsyncStream.makeStream(of: ExpiringCredentials.self)
        self.currentCredentials = CurrentCredentials(credentials: self.expiringCredentials,
                                                     expiringCredentialsRetriever: expiringCredentialsRetriever,
                                                     logger: logger,
                                                     credentialsStreamContinuation: self.credentialsStream.continuation,
                                                     expirationBufferSeconds: expirationBufferSeconds,
                                                     backgroundExpirationBufferSeconds: backgroundExpirationBufferSeconds)
    }

    public init(expiringCredentialsRetriever: ExpiringCredentialsAsyncRetriever,
                roleSessionName: String?,
                logger: Logger,
                expirationBufferSeconds: Double = 120.0, // 2 minutes
                backgroundExpirationBufferSeconds: Double = 300.0) async throws { // 5 minutes
        self.expiringCredentials = try await expiringCredentialsRetriever.getCredentials()
        self.status = .initialized
        
        self.credentialsStream = AsyncStream.makeStream(of: ExpiringCredentials.self)
        self.currentCredentials = CurrentCredentials(credentials: self.expiringCredentials,
                                                     expiringCredentialsRetriever: expiringCredentialsRetriever,
                                                     logger: logger,
                                                     credentialsStreamContinuation: self.credentialsStream.continuation,
                                                     expirationBufferSeconds: expirationBufferSeconds,
                                                     backgroundExpirationBufferSeconds: backgroundExpirationBufferSeconds)
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
        self.statusLock.withLock {
            // if there is currently a worker to shutdown
            switch status {
                case .initialized:
                    // no worker ever started, can just go straight to stopped
                    status = .stopped
                    self.credentialsStream.continuation.finish()
                    completedSemaphore.signal()
                case .running:
                    status = .shuttingDown
                    self.credentialsStream.continuation.finish()
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
            self.credentialsStream.continuation.finish()
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
    
    public func getCredentials() async throws -> Credentials {
        
        return try await self.currentCredentials.get()
    }

    func run() async {
        await self.currentCredentials.startBackgroundRefreshTaskIfRequired()
        
        for await credentials in self.credentialsStream.stream {
            self.statusLock.withLock {
                self.expiringCredentials = credentials
            }
        }
        
        // cancel any background tasks
        await self.currentCredentials.stop()
        
        self.statusLock.withLock {
            status = .stopped
            completedSemaphore.signal()
        }
    }
}

#if swift(<5.9.0)
// This should be removed once we support Swift 5.9+
extension AsyncStream {
    fileprivate static func makeStream(
        of elementType: Element.Type = Element.self,
        bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded
    ) -> (stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation) {
        var continuation: AsyncStream<Element>.Continuation!
        let stream = AsyncStream<Element>(bufferingPolicy: limit) { continuation = $0 }
        return (stream: stream, continuation: continuation!)
    }
}
#endif
