/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import Foundation

/// Sends Telemetry events to RUM.
///
/// `RUMTelemetry` complies to `Telemetry` protocol allowing sending telemetry
/// events accross features.
///
/// Events are reported up to 100 per sessions with a sampling mechanism that is
/// configured at initialisation. Duplicates are discared.
internal final class RUMTelemetry: Telemetry {
    /// Maximium number of telemetry events allowed per user sessions.
    static let MaxEventsPerSessions: Int = 100

    let sdkVersion: String
    let applicationID: String
    let source: String
    let dateProvider: DateProvider
    let dateCorrector: DateCorrectorType
    let sampler: Sampler

    /// Keeps track of current session
    private var currentSessionID: RUMUUID = .nullUUID

    /// Keeps track of event's ids recorded during a user session.
    private var eventIDs: Set<String> = []

    /// Creates a RUM Telemetry instance.
    ///
    /// - Parameters:
    ///   - sdkVersion: The Datadog SDK version.
    ///   - applicationID: The application ID.
    ///   - dateProvider: Current device time provider.
    ///   - dateCorrector: Date correction for adjusting device time to server time.
    ///   - sampler: Telemetry events sampler.
    init(
        sdkVersion: String,
        applicationID: String,
        source: String,
        dateProvider: DateProvider,
        dateCorrector: DateCorrectorType,
        sampler: Sampler
    ) {
        self.sdkVersion = sdkVersion
        self.applicationID = applicationID
        self.source = source
        self.dateProvider = dateProvider
        self.dateCorrector = dateCorrector
        self.sampler = sampler
    }

    /// Sends a `TelemetryDebugEvent` event.
    /// see. https://github.com/DataDog/rum-events-format/blob/master/schemas/telemetry/debug-schema.json
    ///
    /// The current RUM context info is applied if available, including session ID, view ID,
    /// and action ID.
    ///
    /// - Parameters:
    ///   - id: Identity of the debug log, this can be used to prevent duplicates.
    ///   - message: The debug message.
    func debug(id: String, message: String) {
        let date = dateCorrector.currentCorrection.applying(to: dateProvider.currentDate())

        record(event: id) { context, writer in
            let actionId = context.activeUserActionID?.toRUMDataFormat
            let viewId = context.activeViewID?.toRUMDataFormat
            let sessionId = context.sessionID == RUMUUID.nullUUID ? nil : context.sessionID.toRUMDataFormat

            let event = TelemetryDebugEvent(
                dd: .init(),
                action: actionId.map { .init(id: $0) },
                application: .init(id: self.applicationID),
                date: date.timeIntervalSince1970.toInt64Milliseconds,
                service: "dd-sdk-ios",
                session: sessionId.map { .init(id: $0) },
                source: TelemetryDebugEvent.Source(rawValue: self.source) ?? .ios,
                telemetry: .init(message: message),
                version: self.sdkVersion,
                view: viewId.map { .init(id: $0) }
            )

            writer.write(value: event)
        }
    }

    /// Sends a `TelemetryErrorEvent` event.
    /// see. https://github.com/DataDog/rum-events-format/blob/master/schemas/telemetry/error-schema.json
    ///
    /// The current RUM context info is applied if available, including session ID, view ID,
    /// and action ID.
    ///
    /// - Parameters:
    ///   - id: Identity of the debug log, this can be used to prevent duplicates.
    ///   - message: Body of the log
    ///   - kind: The error type or kind (or code in some cases).
    ///   - stack: The stack trace or the complementary information about the error.
    func error(id: String, message: String, kind: String?, stack: String?) {
        let date = dateCorrector.currentCorrection.applying(to: dateProvider.currentDate())

        record(event: id) { context, writer in
            let actionId = context.activeUserActionID?.toRUMDataFormat
            let viewId = context.activeViewID?.toRUMDataFormat
            let sessionId = context.sessionID == RUMUUID.nullUUID ? nil : context.sessionID.toRUMDataFormat

            let event = TelemetryErrorEvent(
                dd: .init(),
                action: actionId.map { .init(id: $0) },
                application: .init(id: self.applicationID),
                date: date.timeIntervalSince1970.toInt64Milliseconds,
                service: "dd-sdk-ios",
                session: sessionId.map { .init(id: $0) },
                source: TelemetryErrorEvent.Source(rawValue: self.source) ?? .ios,
                telemetry: .init(error: .init(kind: kind, stack: stack), message: message),
                version: self.sdkVersion,
                view: viewId.map { .init(id: $0) }
            )

            writer.write(value: event)
        }
    }

    private func record(event id: String, operation: @escaping (RUMContext, Writer) -> Void) {
        guard
            sampler.sample(),
            let monitor = Global.rum as? RUMMonitor,
            let writer = RUMFeature.instance?.storage.writer
        else {
            return
        }

        monitor.contextProvider.async { context in
            // reset recorded events on session renewal
            if context.sessionID != self.currentSessionID {
                self.currentSessionID = context.sessionID
                self.eventIDs = []
            }

            // record up de `MaxEventsPerSessions`, discard duplicates
            if self.eventIDs.count < RUMTelemetry.MaxEventsPerSessions, !self.eventIDs.contains(id) {
                self.eventIDs.insert(id)
                operation(context, writer)
            }
        }
    }
}
