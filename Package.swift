// swift-tools-version:5.2
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
    name: "smoke-aws-credentials",
    platforms: [
        .macOS(.v10_15), .iOS(.v10)
        ],
    products: [
        .library(
            name: "SmokeAWSCredentials",
            targets: ["SmokeAWSCredentials"]),
    ],
    dependencies: [
        .package(url: "https://github.com/amzn/smoke-aws.git", from: "2.0.0-alpha.6"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "SmokeAWSCredentials", dependencies: [
                .product(name: "SecurityTokenClient", package: "smoke-aws"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ]),
        .testTarget(
            name: "SmokeAWSCredentialsTests", dependencies: [
                .target(name: "SmokeAWSCredentials"),
            ]),
    ],
    swiftLanguageVersions: [.v5]
)
