import XCTest
@testable import AwsOpenTelemetryCore
@testable import TestUtils
import OpenTelemetryApi
import OpenTelemetrySdk

class MockStackTraceCollector: LiveStackTraceReporter {
  var maxStackTraceLength: Int
  var shouldReturnStackTrace: Bool = true
  var mockStackTraceData: Data = "mock stack trace data".data(using: .utf8)!
  var mockStackTrace: StackTrace = .init(
    message: "Hang detected at MockFunction",
    stacktrace: "Thread 0:\n0 MockFunction + 123\n1 AnotherFunction + 456"
  )

  required init(maxStackTraceLength: Int = 10000) {
    self.maxStackTraceLength = maxStackTraceLength
  }

  func generateLiveStackTrace() -> Data? {
    return shouldReturnStackTrace ? mockStackTraceData : nil
  }

  func formatStackTrace(rawStackTrace: Data) -> StackTrace {
    return mockStackTrace
  }
}

final class AwsHangInstrumentationTests: XCTestCase {
  var mockStackTraceCollector: MockStackTraceCollector!
  var spanExporter: InMemorySpanExporter!
  var instrumentation: AwsHangInstrumentation!

  override func setUp() {
    super.setUp()
    mockStackTraceCollector = MockStackTraceCollector()
    spanExporter = InMemorySpanExporter.register()
    instrumentation = AwsHangInstrumentation(stackTraceCollector: mockStackTraceCollector)
  }

  override func tearDown() {
    spanExporter.clear()
    instrumentation = nil
    mockStackTraceCollector = nil
    spanExporter = nil
    super.tearDown()
  }

  func testInitialization() {
    XCTAssertEqual(instrumentation.hangThreshold, 0.25)
    XCTAssertEqual(instrumentation.hangPredetectionThreshold, 0.25 * 2 / 3)
    XCTAssertNotNil(instrumentation.stackTraceCollector)
    XCTAssertNil(instrumentation.hangStart)
    XCTAssertNil(instrumentation.rawStackTrace)
  }

  func testCheckForOngoingHangWithoutHangStart() {
    instrumentation.hangStart = nil
    instrumentation.checkForOngoingHang()
    XCTAssertNil(instrumentation.rawStackTrace)
  }

  func testCheckForOngoingHangWithExistingStackTrace() {
    let testTime = CFAbsoluteTimeGetCurrent()
    instrumentation.hangStart = testTime
    instrumentation.rawStackTrace = "existing".data(using: .utf8)!

    instrumentation.checkForOngoingHang()

    XCTAssertEqual(instrumentation.rawStackTrace, "existing".data(using: .utf8)!)
  }

  func testCheckForOngoingHangBelowThreshold() {
    let testTime = CFAbsoluteTimeGetCurrent() - 0.1
    instrumentation.hangStart = testTime
    instrumentation.rawStackTrace = nil

    instrumentation.checkForOngoingHang()

    XCTAssertNil(instrumentation.rawStackTrace)
  }

  func testCheckForOngoingHangAboveThreshold() {
    let testTime = CFAbsoluteTimeGetCurrent() - 0.2
    instrumentation.hangStart = testTime
    instrumentation.rawStackTrace = nil
    mockStackTraceCollector.shouldReturnStackTrace = true

    instrumentation.checkForOngoingHang()

    XCTAssertNotNil(instrumentation.rawStackTrace)
    XCTAssertEqual(instrumentation.rawStackTrace, mockStackTraceCollector.mockStackTraceData)
  }

  func testReportHangWithStackTrace() {
    let startTime: CFAbsoluteTime = 12345.0
    let endTime: CFAbsoluteTime = 12345.5
    let testStackTrace = "test stack trace".data(using: .utf8)!

    instrumentation.rawStackTrace = testStackTrace
    instrumentation.reportHang(startTime: startTime, endTime: endTime)

    let expectation = XCTestExpectation(description: "Span creation")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)

    XCTAssertEqual(spanExporter.getExportedSpans().count, 1)

    let span = spanExporter.getExportedSpans().first!
    XCTAssertEqual(span.name, "device.hang")
    XCTAssertEqual(span.attributes["exception.type"]?.description, "hang")
    XCTAssertEqual(span.attributes["exception.message"]?.description, mockStackTraceCollector.mockStackTrace.message)
    XCTAssertEqual(span.attributes["exception.stacktrace"]?.description, mockStackTraceCollector.mockStackTrace.stacktrace)
  }

  func testReportHangWithoutStackTrace() {
    let startTime: CFAbsoluteTime = 12345.0
    let endTime: CFAbsoluteTime = 12345.5

    instrumentation.rawStackTrace = nil
    instrumentation.reportHang(startTime: startTime, endTime: endTime)

    let expectation = XCTestExpectation(description: "Span creation")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)

    XCTAssertEqual(spanExporter.getExportedSpans().count, 1)

    let span = spanExporter.getExportedSpans().first!
    XCTAssertEqual(span.name, "device.hang")
    XCTAssertEqual(span.attributes["exception.type"]?.description, "hang")
    XCTAssertEqual(span.attributes["exception.message"]?.description, "Hang detected at unknown location")
    XCTAssertEqual(span.attributes["exception.stacktrace"]?.description, "No stack trace captured")
  }

  // TC PATCH: only foreground time counts toward a hang. These drive the run loop and app-state
  // handlers with fixed timestamps, so no stack is captured: the live watchdog would otherwise see
  // a years-long hang, collect one, and move reportHang onto its async path.

  private func exportedSpans() -> [SpanData] {
    let expectation = XCTestExpectation(description: "Span export")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
    return spanExporter.getExportedSpans()
  }

  func testPassInForegroundReportsHang() {
    mockStackTraceCollector.shouldReturnStackTrace = false
    instrumentation.runLoopDidWake(at: 100.0)
    instrumentation.runLoopWillSleep(at: 100.4)

    let spans = exportedSpans()
    XCTAssertEqual(spans.count, 1)
    XCTAssertEqual(spans.first?.endTime.timeIntervalSince(spans.first!.startTime) ?? 0, 0.4, accuracy: 0.001)
  }

  func testLeavingForegroundAtStartOfPassDropsHang() {
    mockStackTraceCollector.shouldReturnStackTrace = false
    instrumentation.runLoopDidWake(at: 100.0)
    instrumentation.appDidLeaveForeground(at: 100.01)
    instrumentation.runLoopWillSleep(at: 100.5)

    XCTAssertTrue(exportedSpans().isEmpty)
  }

  func testLeavingForegroundEndsHangAtThatMoment() {
    mockStackTraceCollector.shouldReturnStackTrace = false
    instrumentation.runLoopDidWake(at: 100.0)
    instrumentation.appDidLeaveForeground(at: 100.3)
    instrumentation.appDidLeaveForeground(at: 100.4) // didEnterBackground after willResignActive
    instrumentation.runLoopWillSleep(at: 102.0)

    let spans = exportedSpans()
    XCTAssertEqual(spans.count, 1)
    XCTAssertEqual(spans.first?.endTime.timeIntervalSince(spans.first!.startTime) ?? 0, 0.3, accuracy: 0.001)
  }

  func testPassStartedInBackgroundIsNotCounted() {
    mockStackTraceCollector.shouldReturnStackTrace = false
    instrumentation.appDidLeaveForeground(at: 99.0)
    instrumentation.runLoopDidWake(at: 100.0)
    instrumentation.checkForOngoingHang()
    instrumentation.runLoopWillSleep(at: 120.0)

    XCTAssertNil(instrumentation.rawStackTrace)
    XCTAssertTrue(exportedSpans().isEmpty)
  }

  func testBecomingActiveCountsFromThatMoment() {
    mockStackTraceCollector.shouldReturnStackTrace = false
    instrumentation.appDidLeaveForeground(at: 99.0)
    instrumentation.runLoopDidWake(at: 100.0)
    instrumentation.appDidBecomeActive(at: 101.0)
    instrumentation.runLoopWillSleep(at: 101.3)

    let spans = exportedSpans()
    XCTAssertEqual(spans.count, 1)
    XCTAssertEqual(spans.first?.endTime.timeIntervalSince(spans.first!.startTime) ?? 0, 0.3, accuracy: 0.001)
  }

  func testBecomingActiveMidForegroundPassKeepsItsStart() {
    mockStackTraceCollector.shouldReturnStackTrace = false
    instrumentation.runLoopDidWake(at: 100.0) // launch: inactive is still the foreground
    instrumentation.appDidBecomeActive(at: 100.2)
    instrumentation.runLoopWillSleep(at: 100.4)

    let spans = exportedSpans()
    XCTAssertEqual(spans.count, 1)
    XCTAssertEqual(spans.first?.endTime.timeIntervalSince(spans.first!.startTime) ?? 0, 0.4, accuracy: 0.001)
  }

  func testBriefTripOutWithinOnePassCountsOnlyTheLastForegroundStretch() {
    mockStackTraceCollector.shouldReturnStackTrace = false
    instrumentation.runLoopDidWake(at: 100.0)
    instrumentation.appDidLeaveForeground(at: 100.2)
    instrumentation.appDidBecomeActive(at: 100.5)
    instrumentation.runLoopWillSleep(at: 100.6)

    XCTAssertTrue(exportedSpans().isEmpty)
  }

  func testPassSuspendedWithoutLeavingCountsFromReturn() {
    mockStackTraceCollector.shouldReturnStackTrace = false
    instrumentation.runLoopDidWake(at: 100.0)
    instrumentation.appWillEnterForeground(at: 2500.0)
    instrumentation.appDidBecomeActive(at: 2500.1)
    instrumentation.runLoopWillSleep(at: 2500.2)

    XCTAssertTrue(exportedSpans().isEmpty)
  }

  func testForegroundResumesCountingOnNextPass() {
    mockStackTraceCollector.shouldReturnStackTrace = false
    instrumentation.appDidLeaveForeground(at: 99.0)
    instrumentation.appDidBecomeActive(at: 99.5)
    instrumentation.runLoopWillSleep(at: 99.6)
    instrumentation.runLoopDidWake(at: 100.0)
    instrumentation.runLoopWillSleep(at: 100.3)

    XCTAssertEqual(exportedSpans().count, 1)
  }

  func testSharedInstance() {
    let shared1 = AwsHangInstrumentation.shared
    let shared2 = AwsHangInstrumentation.shared

    XCTAssertTrue(shared1 === shared2)
  }

  func testQueueConfiguration() {
    XCTAssertNotNil(instrumentation.syncQueue)
    XCTAssertNotNil(instrumentation.watchdogQueue)

    let syncQueueLabel = instrumentation.syncQueue.label
    let watchdogQueueLabel = instrumentation.watchdogQueue.label

    XCTAssertTrue(syncQueueLabel.contains(AwsInstrumentationScopes.HANG))
    XCTAssertEqual(watchdogQueueLabel, AwsInstrumentationScopes.HANG)
  }
}
