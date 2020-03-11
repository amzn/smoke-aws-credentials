// swift-tools-version:5.0
//
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

import PackageDescription

let package = Package(
    name: "SmokeAWSCredentials",
    platforms: [
        .macOS(.v10_12), .iOS(.v10)
        ],
    products: [
        .library(
            name: "SmokeAWSCredentials",
            targets: ["SmokeAWSCredentials"]),
    ],
    dependencies: [
        .package(url: "https://github.com/amzn/smoke-aws.git", from: "2.0.0-alpha.4"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "SmokeAWSCredentials",
            dependencies: ["SecurityTokenClient", "NIO", "NIOHTTP1", "NIOFoundationCompat", "Logging"]),
        .testTarget(
            name: "SmokeAWSCredentialsTests",
            dependencies: ["SmokeAWSCredentials"]),
    ],
    swiftLanguageVersions: [.v5]
)
