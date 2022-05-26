/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import XCTest
@testable import Datadog

class LoggingFeatureTests: XCTestCase {
    let core = DatadogCoreMock()

    override func setUp() {
        super.setUp()
        XCTAssertFalse(Datadog.isInitialized)
        temporaryDirectory.create()
    }

    override func tearDown() {
        XCTAssertFalse(Datadog.isInitialized)
        core.flush()
        temporaryDirectory.delete()
        super.tearDown()
    }

    // MARK: - HTTP Message

    func testItUsesExpectedHTTPMessage() throws {
        let randomApplicationName: String = .mockRandom(among: .alphanumerics)
        let randomApplicationVersion: String = .mockRandom()
        let randomSource: String = .mockRandom(among: .alphanumerics)
        let randomOrigin: String = .mockRandom(among: .alphanumerics)
        let randomSDKVersion: String = .mockRandom(among: .alphanumerics)
        let randomUploadURL: URL = .mockRandom()
        let randomClientToken: String = .mockRandom()
        let randomDeviceModel: String = .mockRandom()
        let randomDeviceOSName: String = .mockRandom()
        let randomDeviceOSVersion: String = .mockRandom()
        let randomEncryption: DataEncryption? = Bool.random() ? DataEncryptionMock() : nil

        let server = ServerMock(delivery: .success(response: .mockResponseWith(statusCode: 200)))

        // Given
        let feature: LoggingFeature = .mockWith(
            directory: temporaryDirectory,
            configuration: .mockWith(
                common: .mockWith(
                    clientToken: randomClientToken,
                    applicationName: randomApplicationName,
                    applicationVersion: randomApplicationVersion,
                    source: randomSource,
                    origin: randomOrigin,
                    sdkVersion: randomSDKVersion,
                    encryption: randomEncryption
                ),
                uploadURL: randomUploadURL
            ),
            dependencies: .mockWith(
                mobileDevice: .mockWith(model: randomDeviceModel, osName: randomDeviceOSName, osVersion: randomDeviceOSVersion)
            )
        )
        core.register(feature: feature)

        // When
        let logger = Logger.builder.build(in: core)
        logger.debug(.mockAny())

        // Then
        let request = server.waitAndReturnRequests(count: 1)[0]
        let requestURL = try XCTUnwrap(request.url)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(requestURL.absoluteString.starts(with: randomUploadURL.absoluteString + "?"))
        XCTAssertEqual(requestURL.query, "ddsource=\(randomSource)")
        XCTAssertEqual(
            request.allHTTPHeaderFields?["User-Agent"],
            """
            \(randomApplicationName)/\(randomApplicationVersion) CFNetwork (\(randomDeviceModel); \(randomDeviceOSName)/\(randomDeviceOSVersion))
            """
        )
        XCTAssertEqual(request.allHTTPHeaderFields?["Content-Type"], "application/json")
        XCTAssertEqual(request.allHTTPHeaderFields?["Content-Encoding"], "deflate")
        XCTAssertEqual(request.allHTTPHeaderFields?["DD-API-KEY"], randomClientToken)
        XCTAssertEqual(request.allHTTPHeaderFields?["DD-EVP-ORIGIN"], randomOrigin)
        XCTAssertEqual(request.allHTTPHeaderFields?["DD-EVP-ORIGIN-VERSION"], randomSDKVersion)
        XCTAssertEqual(request.allHTTPHeaderFields?["DD-REQUEST-ID"]?.matches(regex: .uuidRegex), true)
    }

    // MARK: - HTTP Payload

    func testItUsesExpectedPayloadFormatForUploads() throws {
        let server = ServerMock(delivery: .success(response: .mockResponseWith(statusCode: 200)))
        let feature: LoggingFeature = .mockWith(
            directory: temporaryDirectory,
            dependencies: .mockWith(
                performance: .combining(
                    storagePerformance: StoragePerformanceMock(
                        maxFileSize: .max,
                        maxDirectorySize: .max,
                        maxFileAgeForWrite: .distantFuture, // write all spans to single file,
                        minFileAgeForRead: StoragePerformanceMock.readAllFiles.minFileAgeForRead,
                        maxFileAgeForRead: StoragePerformanceMock.readAllFiles.maxFileAgeForRead,
                        maxObjectsInFile: 3, // write 3 spans to payload,
                        maxObjectSize: .max
                    ),
                    uploadPerformance: UploadPerformanceMock(
                        initialUploadDelay: 0.5, // wait enough until spans are written,
                        minUploadDelay: 1,
                        maxUploadDelay: 1,
                        uploadDelayChangeRate: 0
                    )
                )
            )
        )
        core.register(feature: feature)

        let logger = Logger.builder.build(in: core)
        logger.debug("log 1")
        logger.debug("log 2")
        logger.debug("log 3")

        let payload = try XCTUnwrap(server.waitAndReturnRequests(count: 1)[0].httpBody)

        // Expected payload format:
        // `[log1JSON,log2JSON,log3JSON]`

        XCTAssertEqual(payload.prefix(1).utf8String, "[", "payload should start with JSON array trait: `[`")
        XCTAssertEqual(payload.suffix(1).utf8String, "]", "payload should end with JSON array trait: `]`")

        // Expect payload to be an array of log JSON objects
        let logMatchers = try LogMatcher.fromArrayOfJSONObjectsData(payload)
        logMatchers[0].assertMessage(equals: "log 1")
        logMatchers[1].assertMessage(equals: "log 2")
        logMatchers[2].assertMessage(equals: "log 3")
    }
}
