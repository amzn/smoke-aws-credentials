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
//  AwsRotatingCredentials.swift
//  SmokeAWSCredentials
//

import Foundation
import SmokeAWSCore
import LoggerAPI

#if os(Linux)
	import Glibc
#else
	import Darwin
#endif

/**
 A protocol that retrieves `ExpiringCredentials` and that is closable.
 */
public protocol ExpiringCredentialsRetriever {
    
    /**
     Gracefully shuts down this retriever. This function is idempotent and
     will handle being called multiple times.
     */
    func close()

    /**
     Waits for the retriever to be closed. If close() is not called,
     this will block forever.
     */
    func wait()
    
    /**
     Retrieves a new instance of `ExpiringCredentials`.
     */
    func get() throws -> ExpiringCredentials
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
        return expiringCredentials
    }
    
    private var expiringCredentials: ExpiringCredentials
    let queue = DispatchQueue.global()
    
    public enum Status {
        case initialized
        case running
        case shuttingDown
        case stopped
    }
    
    public var status: Status
    var currentWorker: (() -> ())?
    let completedSemaphore = DispatchSemaphore(value: 0)
    var statusMutex: pthread_mutex_t
    let expiringCredentialsRetriever: ExpiringCredentialsRetriever
    
    /**
     Initializer that accepts the initial ExpiringCredentials instance for this provider.
     
     - Parameters:
        - expiringCredentialsRetriever: retriever of expiring credentials.
     */
    public init(expiringCredentialsRetriever: ExpiringCredentialsRetriever) throws {
        self.expiringCredentials = try expiringCredentialsRetriever.get()
        self.currentWorker = nil
        self.expiringCredentialsRetriever = expiringCredentialsRetriever
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
        stop()
        wait()
    }
    
    /**
     Schedules credentials rotation to begin.
     */
    public func start(roleSessionName: String?) {
        guard case .initialized = status else {
            // if this instance isn't in the initialized state, do nothing
            return
        }
        
        // only actually need to start updating credentials if the
        // initial ones expire
        if let expiration = expiringCredentials.expiration {
            scheduleUpdateCredentials(beforeExpiration: expiration,
                                      roleSessionName: roleSessionName)
        }
    }
    
    /**
     Gracefully shuts down credentials rotation, letting any ongoing work complete..
     */
    public func stop() {
        pthread_mutex_lock(&statusMutex)
        defer { pthread_mutex_unlock(&statusMutex) }
        
        // if there is currently a worker to shutdown
        switch status {
        case .initialized:
            // no worker ever started, can just go straight to stopped
            status = .stopped
            expiringCredentialsRetriever.close()
            completedSemaphore.signal()
        case .running:
            status = .shuttingDown
        default:
            // nothing to do
            break
        }
    }
    
    private func verifyWorkerNotStopped() -> Bool {
        pthread_mutex_lock(&statusMutex)
        defer { pthread_mutex_unlock(&statusMutex) }
        
        guard case .stopped = status else {
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
        
        completedSemaphore.wait()
    }
    
    private func verifyWorkerNotCancelled() -> Bool {
        pthread_mutex_lock(&statusMutex)
        defer { pthread_mutex_unlock(&statusMutex) }
        
        guard case .running = status else {
            status = .stopped
            expiringCredentialsRetriever.close()
            completedSemaphore.signal()
            return false
        }
        
        return true
    }
    
    private func scheduleUpdateCredentials(beforeExpiration expiration: Date,
                                           roleSessionName: String?) {
        // create a deadline 5 minutes before the expiration
        let timeInterval = (expiration - 300).timeIntervalSinceNow
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
            
            Log.verbose("\(logEntryPrefix) about to expire; rotating.")
            
            let expiringCredentials: ExpiringCredentials
            do {
                expiringCredentials = try self.expiringCredentialsRetriever.get()
            } catch {
                return Log.error("\(logEntryPrefix) rotation failed.")
            }
            
            self.expiringCredentials = expiringCredentials
            
            // if there is an expiry, schedule a rotation
            if let expiration = expiringCredentials.expiration {
                self.scheduleUpdateCredentials(beforeExpiration: expiration,
                                               roleSessionName: roleSessionName)
            }
        }
        
        Log.info("\(logEntryPrefix) updated; rotation scheduled in \(hours) hours, \(minutes) minutes.")
        queue.asyncAfter(deadline: deadline, execute: newWorker)
        
        pthread_mutex_lock(&statusMutex)
        defer { pthread_mutex_unlock(&statusMutex) }
        
        self.status = .running
        self.currentWorker = newWorker
    }
}
