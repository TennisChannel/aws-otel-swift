/*
 * Copyright Amazon.com, Inc. or its affiliates.
 *
 * Licensed under the Apache License, Version 2.0 (the "License").
 * You may not use this file except in compliance with the License.
 * A copy of the License is located at
 *
 *  http://aws.amazon.com/apache2.0
 *
 * or in the "license" file accompanying this file. This file is distributed
 * on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
 * express or implied. See the License for the specific language governing
 * permissions and limitations under the License.
 */

import XCTest
import OpenTelemetrySdk
import OpenTelemetryApi
@testable import AwsOpenTelemetryCore
@testable import TestUtils

#if canImport(KSCrash)
  import KSCrash
#endif

final class AwsKSCrashInstrumentationTests: XCTestCase {
  private var inMemoryExporter: InMemoryLogExporter!

  override func setUp() {
    super.setUp()
    inMemoryExporter = InMemoryLogExporter.register()
  }

  override func tearDown() {
    inMemoryExporter.reset()
    NotificationCenter.default.removeObserver(self)
    super.tearDown()
  }

  func testCacheCrashContext() {
    let session = AwsSession(
      id: "cache-session-id",
      expireTime: Date(timeIntervalSinceNow: 1800),
      previousId: "cache-prev-id"
    )

    AwsKSCrashInstrumentation.cacheCrashContext(session: session)

    let userInfo = AwsKSCrashInstrumentation.reporter.userInfo as? [String: String]
    XCTAssertEqual(userInfo?[AwsSessionSemConv.id], "cache-session-id")
    XCTAssertEqual(userInfo?[AwsSessionSemConv.previousId], "cache-prev-id")
    XCTAssertNotNil(userInfo?["user.id"])
  }

  func testReporterConfiguration() {
    XCTAssertNotNil(AwsKSCrashInstrumentation.reporter)
  }

  func testMaxStackTraceBytes() {
    XCTAssertEqual(AwsKSCrashInstrumentation.maxStackTraceBytes, 25 * 1024)
  }

  // TC PATCH
  private func terminationReport(reason: String, userPerceptible: Any, state: String = "background",
                                 taskRole: String? = "NONUI_APPLICATION") -> [String: Any] {
    var appStats: [String: Any] = ["app_transition_state": state, "user_perceptible": userPerceptible]
    appStats["task_role"] = taskRole
    return [
      "report": ["monitor_id": "Termination"],
      "system": ["application_stats": appStats],
      "crash": ["error": ["type": "termination", "termination_reason": reason]]
    ]
  }

  func testSkipsUnexplainedTerminationOfBackgroundLaunch() {
    for state in ["startup", "launching"] {
      for role in ["BACKGROUND_APPLICATION", "UNKNOWN"] {
        XCTAssertTrue(AwsKSCrashInstrumentation.isUnperceivedUnexplainedTermination(
          terminationReport(reason: "unexplained", userPerceptible: true, state: state, taskRole: role)), "\(state) \(role)")
      }
    }
  }

  func testKeepsUnexplainedTerminationOfForegroundLaunch() {
    XCTAssertFalse(AwsKSCrashInstrumentation.isUnperceivedUnexplainedTermination(
      terminationReport(reason: "unexplained", userPerceptible: true, state: "startup", taskRole: "FOREGROUND_APPLICATION")))
    XCTAssertFalse(AwsKSCrashInstrumentation.isUnperceivedUnexplainedTermination(
      terminationReport(reason: "unexplained", userPerceptible: true, state: "startup", taskRole: nil)))
    XCTAssertFalse(AwsKSCrashInstrumentation.isUnperceivedUnexplainedTermination(
      terminationReport(reason: "unexplained", userPerceptible: true, state: "active", taskRole: "BACKGROUND_APPLICATION")))
    XCTAssertFalse(AwsKSCrashInstrumentation.isUnperceivedUnexplainedTermination(
      terminationReport(reason: "memory_limit", userPerceptible: true, state: "startup", taskRole: "BACKGROUND_APPLICATION")))
  }

  func testSkipsUnexplainedTerminationWhenNotPerceptible() {
    XCTAssertTrue(AwsKSCrashInstrumentation.isUnperceivedUnexplainedTermination(
      terminationReport(reason: "unexplained", userPerceptible: false)))
    XCTAssertTrue(AwsKSCrashInstrumentation.isUnperceivedUnexplainedTermination(
      terminationReport(reason: "unexplained", userPerceptible: NSNumber(value: 0))))
  }

  func testKeepsUnexplainedTerminationWhenPerceptible() {
    XCTAssertFalse(AwsKSCrashInstrumentation.isUnperceivedUnexplainedTermination(
      terminationReport(reason: "unexplained", userPerceptible: true)))
  }

  func testKeepsResourceTerminations() {
    for reason in ["memory_limit", "memory_pressure", "thermal", "cpu", "low_battery"] {
      XCTAssertFalse(AwsKSCrashInstrumentation.isUnperceivedUnexplainedTermination(
        terminationReport(reason: reason, userPerceptible: false)), reason)
    }
  }

  func testKeepsCrashesAndIncompleteReports() {
    let signalCrash: [String: Any] = [
      "system": ["application_stats": ["user_perceptible": true]],
      "crash": ["error": ["type": "signal", "signal": ["signal": 6, "name": "SIGABRT"]]]
    ]
    XCTAssertFalse(AwsKSCrashInstrumentation.isUnperceivedUnexplainedTermination(signalCrash))
    XCTAssertFalse(AwsKSCrashInstrumentation.isUnperceivedUnexplainedTermination(
      ["crash": ["error": ["termination_reason": "unexplained"]]]))
    XCTAssertFalse(AwsKSCrashInstrumentation.isUnperceivedUnexplainedTermination([:]))
  }

  // TC PATCH
  private func hangReport(monitorId: String = "Watchdog", runID: String = "run-1", hang: [String: Any]? = nil) -> [String: Any] {
    var error: [String: Any] = ["type": "signal", "signal": ["signal": 9], "mach": ["exception": 10]]
    error["hang"] = hang
    return [
      "report": ["monitor_id": monitorId, "run_id": runID],
      "crash": ["error": error]
    ]
  }

  func testOrphanedHangReportIsThisRunsUnfinalizedWatchdogReport() {
    XCTAssertTrue(AwsKSCrashInstrumentation.isOrphanedHangReport(hangReport(), currentRunID: "run-1"))
  }

  func testKeepsHangReportsFromEarlierRuns() {
    XCTAssertFalse(AwsKSCrashInstrumentation.isOrphanedHangReport(hangReport(runID: "run-0"), currentRunID: "run-1"))
  }

  func testKeepsFinalizedHangReports() {
    let finalized = hangReport(hang: ["hang_start_nanos": 1, "recovered": true])
    XCTAssertFalse(AwsKSCrashInstrumentation.isOrphanedHangReport(finalized, currentRunID: "run-1"))
  }

  func testKeepsOtherMonitorsReports() {
    for monitorId in ["Signal", "MachException", "NSException", "Termination"] {
      XCTAssertFalse(AwsKSCrashInstrumentation.isOrphanedHangReport(hangReport(monitorId: monitorId), currentRunID: "run-1"), monitorId)
    }
    XCTAssertFalse(AwsKSCrashInstrumentation.isOrphanedHangReport([:], currentRunID: "run-1"))
    XCTAssertFalse(AwsKSCrashInstrumentation.isOrphanedHangReport(["report": ["monitor_id": "Watchdog", "run_id": "run-1"]],
                                                                  currentRunID: "run-1"))
  }

  func testHangPairCompletesOnSecondNotificationInEitherOrder() {
    let pairs = HangNotificationPairs()
    XCTAssertFalse(pairs.isSecond(.started, startTimestamp: 100))
    XCTAssertFalse(pairs.isSecond(.updated, startTimestamp: 100))
    XCTAssertTrue(pairs.isSecond(.ended, startTimestamp: 100))

    XCTAssertFalse(pairs.isSecond(.ended, startTimestamp: 200))
    XCTAssertTrue(pairs.isSecond(.started, startTimestamp: 200))
  }

  func testHangPairIgnoresRepeatsAndOtherHangs() {
    let pairs = HangNotificationPairs()
    XCTAssertFalse(pairs.isSecond(.started, startTimestamp: 100))
    XCTAssertFalse(pairs.isSecond(.started, startTimestamp: 100))
    XCTAssertFalse(pairs.isSecond(.ended, startTimestamp: 101))
    XCTAssertFalse(pairs.isSecond(.updated, startTimestamp: 100))
  }

  func testHangPairDropsEarlierHangs() {
    let pairs = HangNotificationPairs()
    // A fatal-looking hang that never ended, then a hang that ended before its report was written.
    XCTAssertFalse(pairs.isSecond(.started, startTimestamp: 100))
    XCTAssertFalse(pairs.isSecond(.ended, startTimestamp: 200))
    XCTAssertFalse(pairs.isSecond(.started, startTimestamp: 300))
    // A late Ended for the first hang no longer pairs with anything.
    XCTAssertFalse(pairs.isSecond(.ended, startTimestamp: 100))
    XCTAssertTrue(pairs.isSecond(.ended, startTimestamp: 300))
  }

  func testExtractCrashMessageWithExceptionType() {
    let stackTrace = """
    Exception Type:  EXC_BREAKPOINT (SIGTRAP)
    Thread 0 Crashed:
    0   libswiftCore.dylib            0x000000019ed5c8c4 $ss17_assertionFailure + 172
    """

    let result = AwsKSCrashInstrumentation.extractCrashMessage(from: stackTrace)
    XCTAssertEqual(result, "EXC_BREAKPOINT (SIGTRAP) detected on thread 0 at libswiftCore.dylib + 172")
  }

  func testExtractCrashMessageWithBadAccess() {
    let stackTrace = """
    Exception Type:  EXC_BAD_ACCESS (SIGSEGV)
    Thread 2 Crashed:
    0   MyApp                         0x0000000104abc123 main + 456
    """

    let result = AwsKSCrashInstrumentation.extractCrashMessage(from: stackTrace)
    XCTAssertEqual(result, "EXC_BAD_ACCESS (SIGSEGV) detected on thread 2 at MyApp + 456")
  }

  func testExtractCrashMessageWithoutExceptionType() {
    let stackTrace = """
    Thread 0 Crashed:
    0   libswiftCore.dylib            0x000000019ed5c8c4 $ss17_assertionFailure + 172
    """

    let result = AwsKSCrashInstrumentation.extractCrashMessage(from: stackTrace)
    XCTAssertEqual(result, "Unknown exception detected on thread 0 at libswiftCore.dylib + 172")
  }

  func testExtractCrashMessageWithDifferentThread() {
    let stackTrace = """
    Exception Type:  EXC_CRASH (SIGABRT)
    Thread 5 Crashed:
    0   SomeFramework                 0x00000001f14e1a90 someFunction + 8
    """

    let result = AwsKSCrashInstrumentation.extractCrashMessage(from: stackTrace)
    XCTAssertEqual(result, "EXC_CRASH (SIGABRT) detected on thread 5 at SomeFramework + 8")
  }

  func testExtractCrashMessageEdgeCases() {
    XCTAssertEqual(AwsKSCrashInstrumentation.extractCrashMessage(from: ""), "Unknown exception detected at unknown location")
    XCTAssertEqual(AwsKSCrashInstrumentation.extractCrashMessage(from: "Thread Crashed:\n0   SomeFramework"), "Unknown exception detected at unknown location")

    let noThreadCrashed = "Some other content\nThread 1:\n0   libsystem_kernel.dylib"
    XCTAssertEqual(AwsKSCrashInstrumentation.extractCrashMessage(from: noThreadCrashed), "Unknown exception detected at unknown location")
  }

  func testExtractCrashMessageWithWhitespaceHandling() {
    let stackTrace = """
    Exception Type:  EXC_BAD_ACCESS (SIGSEGV)
    Thread 2 Crashed:
    0     MyFramework     \t\t\t    0x123456789    myFunction    +    123
    """

    let result = AwsKSCrashInstrumentation.extractCrashMessage(from: stackTrace)
    XCTAssertEqual(result, "EXC_BAD_ACCESS (SIGSEGV) detected on thread 2 at MyFramework + 123")
  }

  func testExtractCrashMessageWithExceptionTypeOnly() {
    let stackTrace = """
    Exception Type:  EXC_CRASH (SIGABRT)
    """

    let result = AwsKSCrashInstrumentation.extractCrashMessage(from: stackTrace)
    XCTAssertEqual(result, "EXC_CRASH (SIGABRT) detected at unknown location")
  }

  func testExtractCrashMessageWithCompleteInfo() {
    let stackTrace = """
    Exception Type:  EXC_BREAKPOINT (SIGTRAP)
    Thread 0 Crashed:
    0   SomeFramework                 0x123456789 someFunction + 8
    """

    let result = AwsKSCrashInstrumentation.extractCrashMessage(from: stackTrace)
    XCTAssertEqual(result, "EXC_BREAKPOINT (SIGTRAP) detected on thread 0 at SomeFramework + 8")
  }

  func testRecoverCrashContextSuccess() {
    let mockLogBuilder = MockLogRecordBuilder()
    let initialAttributes: [String: AttributeValue] = [
      "exception.type": AttributeValue.string("crash"),
      "recovered_context": AttributeValue.bool(false)
    ]

    let rawCrash: [String: Any] = [
      "report": ["timestamp": "2025-10-28T21:38:55.554842Z"],
      "user": [
        AwsSessionSemConv.id: "test-session-id",
        AwsSessionSemConv.previousId: "test-prev-session-id",
        "user.id": "test-user-id"
      ]
    ]

    let result = AwsKSCrashInstrumentation.recoverCrashContext(
      from: rawCrash,
      log: mockLogBuilder,
      attributes: initialAttributes
    )

    XCTAssertEqual(result["recovered_context"]?.description, "true")
    XCTAssertEqual(result[AwsSessionSemConv.id]?.description, "test-session-id")
    XCTAssertEqual(result[AwsSessionSemConv.previousId]?.description, "test-prev-session-id")
    XCTAssertEqual(result["user.id"]?.description, "test-user-id")
  }

  func testRecoverCrashContextFailureCases() {
    let mockLogBuilder = MockLogRecordBuilder()
    let initialAttributes: [String: AttributeValue] = ["recovered_context": AttributeValue.bool(false)]

    var result = AwsKSCrashInstrumentation.recoverCrashContext(from: [:], log: mockLogBuilder, attributes: initialAttributes)
    XCTAssertEqual(result["recovered_context"]?.description, "false")
    XCTAssertNil(result[AwsSessionSemConv.id])

    let crashWithoutUser = ["report": ["timestamp": "2025-10-28T21:38:55.554842Z"]]
    result = AwsKSCrashInstrumentation.recoverCrashContext(from: crashWithoutUser, log: mockLogBuilder, attributes: initialAttributes)
    XCTAssertEqual(result["recovered_context"]?.description, "false")

    let crashWithInvalidTimestamp = [
      "report": ["timestamp": "invalid-timestamp"],
      "user": [AwsSessionSemConv.id: "test-session-id"]
    ]
    result = AwsKSCrashInstrumentation.recoverCrashContext(from: crashWithInvalidTimestamp, log: mockLogBuilder, attributes: initialAttributes)
    XCTAssertEqual(result["recovered_context"]?.description, "false")
  }

  func testRecoverCrashContextPartialUserInfo() {
    let mockLogBuilder = MockLogRecordBuilder()
    let initialAttributes: [String: AttributeValue] = ["recovered_context": AttributeValue.bool(false)]

    let rawCrash: [String: Any] = [
      "report": ["timestamp": "2025-10-28T21:38:55.554842Z"],
      "user": [AwsSessionSemConv.id: "test-session-id"]
    ]

    let result = AwsKSCrashInstrumentation.recoverCrashContext(
      from: rawCrash,
      log: mockLogBuilder,
      attributes: initialAttributes
    )

    XCTAssertEqual(result["recovered_context"]?.description, "true")
    XCTAssertEqual(result[AwsSessionSemConv.id]?.description, "test-session-id")
    XCTAssertNil(result[AwsSessionSemConv.previousId])
    XCTAssertNil(result["user.id"])
  }

  func testRecoverCrashContextWithOptionalFields() {
    let mockLogBuilder = MockLogRecordBuilder()
    let initialAttributes: [String: AttributeValue] = ["recovered_context": AttributeValue.bool(false)]

    let rawCrash: [String: Any] = [
      "report": ["timestamp": "2025-10-28T21:38:55.554842Z"],
      "user": [
        AwsSessionSemConv.id: "test-session-id",
        AwsViewSemConv.screenName: "TestScreen"
      ]
    ]

    let result = AwsKSCrashInstrumentation.recoverCrashContext(
      from: rawCrash,
      log: mockLogBuilder,
      attributes: initialAttributes
    )

    XCTAssertEqual(result["recovered_context"]?.description, "true")
    XCTAssertEqual(result[AwsViewSemConv.screenName]?.description, "TestScreen")
  }

  func testCacheCrashContextVariations() {
    AwsKSCrashInstrumentation.cacheCrashContext(session: nil, userId: nil, screenName: nil)

    let session = AwsSession(id: "specific-session", expireTime: Date(timeIntervalSinceNow: 1800))
    AwsKSCrashInstrumentation.cacheCrashContext(session: session, userId: "specific-user", screenName: "SpecificScreen")
    let userInfo = AwsKSCrashInstrumentation.reporter.userInfo as? [String: String]

    // assert
    XCTAssertEqual(userInfo?[AwsSessionSemConv.id], "specific-session")
    XCTAssertEqual(userInfo?[AwsUserSemvConv.id], "specific-user")
    XCTAssertEqual(userInfo?[AwsViewSemConv.screenName], "SpecificScreen")
  }

  func testNotificationHandling() {
    AwsKSCrashInstrumentation.setupNotificationObservers()
    defer {
      for observer in AwsKSCrashInstrumentation.observers {
        NotificationCenter.default.removeObserver(observer)
      }
      AwsKSCrashInstrumentation.observers.removeAll()
    }

    let session = AwsSession(id: "notification-session", expireTime: Date(timeIntervalSinceNow: 1800))
    NotificationCenter.default.post(name: SessionStartNotification, object: session)

    let expectation = XCTestExpectation(description: "Async crash context update")
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)

    let userInfo = AwsKSCrashInstrumentation.reporter.userInfo as? [String: String]
    XCTAssertEqual(userInfo?[AwsSessionSemConv.id], "notification-session")
  }

  func testInstallMethod() {
    XCTAssertNoThrow(AwsKSCrashInstrumentation.install())
  }

  func testProcessStoredCrashes() {
    XCTAssertNoThrow(AwsKSCrashInstrumentation.processStoredCrashes())
  }
}

class MockLogRecordBuilder: LogRecordBuilder {
  var timestamp: Date?
  var attributes: [String: AttributeValue] = [:]
  var eventName: String?

  func setTimestamp(_ timestamp: Date) -> LogRecordBuilder {
    self.timestamp = timestamp
    return self
  }

  func setObservedTimestamp(_ timestamp: Date) -> LogRecordBuilder { return self }
  func setEventName(_ name: String) -> LogRecordBuilder {
    eventName = name
    return self
  }

  func setSeverity(_ severity: Severity) -> LogRecordBuilder { return self }
  func setBody(_ body: AttributeValue) -> LogRecordBuilder { return self }
  func setAttributes(_ attributes: [String: AttributeValue]) -> LogRecordBuilder {
    self.attributes = attributes
    return self
  }

  func addAttribute(key: String, value: AttributeValue) -> LogRecordBuilder {
    attributes[key] = value
    return self
  }

  func emit() {}
}
