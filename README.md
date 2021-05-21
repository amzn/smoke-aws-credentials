<p align="center">
<a href="https://travis-ci.com/amzn/smoke-aws-credentials">
<img src="https://travis-ci.com/amzn/smoke-aws-credentials.svg?branch=master" alt="Build - Master Branch">
</a>
<a href="http://swift.org">
<img src="https://img.shields.io/badge/swift-5.2|5.3|5.4-orange.svg?style=flat" alt="Swift 5.2, 5.3 and 5.4 Tested">
</a>
<img src="https://img.shields.io/badge/ubuntu-18.04|20.04-yellow.svg?style=flat" alt="Ubuntu 18.04 and 20.04 Tested">
<img src="https://img.shields.io/badge/CentOS-8-yellow.svg?style=flat" alt="CentOS 8 Tested">
<img src="https://img.shields.io/badge/AmazonLinux-2-yellow.svg?style=flat" alt="Amazon Linux 2 Tested">
<a href="https://gitter.im/SmokeServerSide">
<img src="https://img.shields.io/badge/chat-on%20gitter-ee115e.svg?style=flat" alt="Join the Smoke Server Side community on gitter">
</a>
<img src="https://img.shields.io/badge/license-Apache2-blue.svg?style=flat" alt="Apache 2">
</p>

# SmokeAWSCredentials

The SmokeAWSCredentials package is a library for obtaining or assuming short-lived rotating AWS IAM credentials, suitable for being passed to clients from https://github.com/amzn/smoke-aws.

# Conceptual overview

This package provides two mechanisms for obtaining credentials-
* obtaining credentials from a container environment such as Elastic Container Service (ECS)
* assuming credentials using existing credentials

# Getting Started

## Step 1: Add the SmokeAWSCredentials dependency

SmokeAWSCredentials uses the Swift Package Manager. To use the framework, add the following dependency
to your Package.swift and depend on the `SmokeAWSCredentials` target from this package-

For swift-tools version 5.2 and greater-

```swift
dependencies: [
    .package(url: "https://github.com/amzn/smoke-aws-credentials", from: "2.0.0")
]

.target(name: ..., dependencies: [
    ..., 
    .product(name: "SmokeAWSCredentials", package: "smoke-aws-credentials"),
]),
```


For swift-tools version 5.1 and prior-
 
```swift
dependencies: [
    .package(url: "https://github.com/amzn/smoke-aws-credentials", from: "2.0.0")
]

.target(
    name: ...,
    dependencies: [..., "SmokeAWSCredentials"]),
```

## Step 2: Obtain a credentials provider from a container environment such as Elastic Container Service (ECS)

Once your application is depending in SmokeAWSCredentials, you can use `AwsContainerRotatingCredentialsProvider` to obtain credentials from a container environment such as Elastic Container Service (ECS).
 
```swift
guard let credentialsProvider = 
    AwsContainerRotatingCredentialsProvider.get() else {
        Log.error("Unable to obtain credentials from the container environment.")
        return
    }
```

The returned provider will mange the short lived credentials and rotate them when required. To get the current credentials-

```swift
    let currentCredentials = credentialsProvider.credentials
```

The credentials returned will be valid for at least *5 minutes* from the time this call is made.

When you no longer need these credentials, you can stop the background credentials rotation.

```swift
    credentialsProvider.stop()
```

## Step 3: Assuming credentials using existing credentials

SmokeAWSCredentials also allows you to assume short-lived credentials - maybe from another account or with different permissions -based on existing credentials. The following API reference discusses how assuming roles is handled-
* https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html


```swift
    guard let assumedCredentials = credentialsProvider.getAssumedRotatingCredentials(
        roleArn: roleArn,
        roleSessionName: roleSessionName,
        durationSeconds: assumedRoleDurationSeconds) else {
            Log.error("Unable to obtain assume credentials for arn '\(roleArn)'.")
            return
    }
```

When you no longer need these credentials, you can stop the background credentials rotation.

```swift
    credentialsProvider.stop()
```

**Note:** If you stop the rotation of the parent credentials provider, the assumed credentials will eventually fail to rotate due to invalid parent credentials.

## Step 4: Using custom credentials in development

It is likely that your development environment will not have the same credentials available as production. `AwsContainerRotatingCredentialsProvider` has the ability to use static credentials from the `AWS_SECRET_ACCESS_KEY` and `AWS_ACCESS_KEY_ID` environment variables if these variables are available. For situations where static credentials are not acceptable, if the `DEBUG` compiler flag and the `AwsContainerRotatingCredentialsProvider.devIamRoleArnEnvironmentVariable` environment variable are set, this library will make the call the following shell script with the provided role-
*  `/usr/local/bin/get-credentials.sh -r <role> -d <role life time in seconds>`

This script can use this role to obtain credentials. If the output of this script can be JSON-decoded with the `ExpiringCredentials` struct, these credentials will be used for this provider. If the script returns credentials with an expiration, the provider will manage rotation, re-calling this script for updated credentials. 

For convenience, `AwsContainerRotatingCredentialsProvider.get` optionally accepts the current environment variables.

```
    #if DEBUG
    let environment = [...,
                       AwsContainerRotatingCredentialsProvider.devIamRoleArnEnvironmentVariable:
                           "arn:aws:iam::000000000000:role/EcsTaskExecutionRole"]
    #else
    let environment = ProcessInfo.processInfo.environment
    #endif
    
    guard let credentialsProvider = 
        AwsContainerRotatingCredentialsProvider.get(fromEnvironment: environment) else {
            return Log.error("Unable to obtain credentials from the container environment.")
    }
```

## License

This library is licensed under the Apache 2.0 License.
