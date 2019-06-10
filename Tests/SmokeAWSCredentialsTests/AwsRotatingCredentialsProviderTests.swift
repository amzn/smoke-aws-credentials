//
//  AwsRotatingCredentialsProviderTests.swift
//  SmokeAWSCredentialsTests
//

import XCTest
@testable import SmokeAWSCredentials

struct AlwaysValidRetriever: ExpiringCredentialsRetriever {
    func close() {
        // nothing to do
    }
    
    func wait() {
        // nothing to do
    }
    
    func get() throws -> ExpiringCredentials {
        return expiringCredentials
    }
}

class SometimesFailRetriever: ExpiringCredentialsRetriever {
    var invocationCount = 0;
    var failureCount = 0;
    
    func close() {
        // nothing to do
    }
    
    func wait() {
        // nothing to do
    }
    
    func get() throws -> ExpiringCredentials {
        invocationCount += 1
        
        guard invocationCount <= 50 else {
            failureCount += 1
            throw SmokeAWSCredentialsError.missingCredentials(reason: "All Wrong!")
        }
        
        return expiringCredentials
    }
}

class CountingScheduler: AsyncAfterScheduler {
    var invocationCount = 0;
    var doWork = true
    
    func asyncAfter(deadline: DispatchTime, qos: DispatchQoS,
                    flags: DispatchWorkItemFlags,
                    execute work: @escaping @convention(block) () -> Void) {
        
        // normally scheduling credentials will call asyncAfter again to schedule more credentials
        // avoid this infinite recursion to explicitly test the scheduling functionality
        if doWork {
            invocationCount += 1
            
            doWork = false
            work()
        }
    }
}

class AwsRotatingCredentialsProviderTests: XCTestCase {
    func testAlwaysSucceedCredentialsRotation() throws {
        let scheduler = CountingScheduler()
        let provider = try AwsRotatingCredentialsProvider(
            expiringCredentialsRetriever: AlwaysValidRetriever(),
            scheduler: scheduler)
        
        // simulate 100 successful credentials
        for _ in 0..<100 {
            let beforeExpiration = Date(timeIntervalSinceNow: 60)
            
            provider.scheduleUpdateCredentials(beforeExpiration: beforeExpiration,
                                               roleSessionName: "roleSessionName")
            // make sure we schedule the credentials once per invocation
            scheduler.doWork = true
        }
        
        XCTAssertEqual(100, scheduler.invocationCount)
    }
    
    func testSometimesFailCredentialsRotation() throws {
        let scheduler = CountingScheduler()
        let retriever = SometimesFailRetriever()
        let provider = try AwsRotatingCredentialsProvider(
            expiringCredentialsRetriever: retriever,
            scheduler: scheduler)
        
        for _ in 0..<100 {
            let beforeExpiration = Date(timeIntervalSinceNow: 60)
            
            provider.scheduleUpdateCredentials(beforeExpiration: beforeExpiration,
                                               roleSessionName: "roleSessionName")
            // make sure we schedule the credentials once per invocation
            scheduler.doWork = true
        }
        
        XCTAssertEqual(100, scheduler.invocationCount)
        XCTAssertEqual(50, retriever.failureCount)
    }
}
