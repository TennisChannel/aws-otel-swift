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

import Foundation
import OpenTelemetryApi

#if canImport(KSCrashRecording)
  import KSCrashRecording
#elseif canImport(KSCrash)
  import KSCrash
#endif

#if canImport(KSCrashFilters)
  import KSCrashFilters
#endif

protocol CrashProtocol {
  static func install()
  static func cacheCrashContext(session: AwsSession?,
                                userId: String?,
                                screenName: String?)

  static func recoverCrashContext(from rawCrash: [String: Any],
                                  log: LogRecordBuilder,
                                  attributes: [String: AttributeValue]) -> [String: AttributeValue]
  static func processStoredCrashes()
}

public class AwsKSCrashInstrumentation: CrashProtocol {
  public static let maxStackTraceBytes = 25 * 1024 // 25 KB
  public private(set) static var isInstalled: Bool = false
  private static let logger = OpenTelemetry.instance.loggerProvider.get(instrumentationScopeName: AwsInstrumentationScopes.KSCRASH)
  static let reporter = KSCrash.shared
  static var observers: [NSObjectProtocol] = []
  /// TC PATCH: see `observeHangReports`.
  static let hangNotifications = HangNotificationPairs()
  private static let queue = DispatchQueue(label: AwsInstrumentationScopes.KSCRASH, qos: .utility)
  private static let timestampFormatter: ISO8601DateFormatter = {
    // Example KSCrash timestamp: `2025-10-28T03:30:53.604204Z`
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [
      .withInternetDateTime,
      .withFractionalSeconds
    ]
    return formatter
  }()

  static func install() {
    guard !isInstalled else {
      AwsInternalLogger.debug("AwsKSCrashInstrumentation already installed")
      return
    }

    do {
      let config = KSCrashConfiguration()
      config.enableSigTermMonitoring = false
      config.enableSwapCxaThrow = false

      try reporter.install(with: config)
      isInstalled = true
      AwsInternalLogger.debug("installed")
    } catch {
      AwsInternalLogger.error("AwsKSCrashInstrumentation failed to install: \(error)")
      return
    }

    // Set initial user info
    cacheCrashContext()

    // Process any stored crashes asynchronously
    queue.async {
      processStoredCrashes()
    }

    // setup cache context subscribers
    setupNotificationObservers()

    observeHangReports()
  }

  /// TC PATCH. KSCrash 2.6's Watchdog monitor writes a fatal hang report (EXC_CRASH / SIGKILL / 0x8badf00d)
  /// as soon as the main thread has been blocked for 250 ms, and deletes it when the hang ends, so only a
  /// hang the process dies in reaches the next launch. If the hang ends while the watchdog thread is still
  /// writing, the main thread clears the hang before the report's path is attached, and the watchdog thread
  /// then discards the hang without deleting the file. The next launch sends it as a crash of a process
  /// that kept running.
  ///
  /// KSCrash notifies Started (watchdog thread) and Ended (main thread) for every hang that ends, in either
  /// order. When the second of the two arrives, KSCrash is done with that hang and no other hang report can
  /// be in flight: the watchdog timer is either invalidated (Ended, inside the main run loop's BeforeWaiting
  /// observer) or busy delivering this callback (Started). A Watchdog report from this run still on disk at
  /// that point is the orphan. A fatal hang never gets an Ended, so its report is never touched.
  static func observeHangReports() {
    let token = kshang_addHangObserver({ change, startTimestamp, _, _ in
      AwsKSCrashInstrumentation.hangDidChange(change, startTimestamp: startTimestamp)
    }, nil)
    if token == KSHangObserverTokenNotFound {
      AwsInternalLogger.debug("AwsKSCrashInstrumentation could not observe hangs (watchdog monitor not running)")
    }
  }

  static func hangDidChange(_ change: HangChangeType, startTimestamp: UInt64) {
    guard hangNotifications.isSecond(change, startTimestamp: startTimestamp),
          let reportStore = reporter.reportStore,
          let runID = kscrash_getRunID() else {
      return
    }
    // Listing the store is cheap and is usually empty; the IDs are taken now so a later hang's report,
    // written after this callback returns, is never a candidate.
    let reportIDs = reportStore.reportIDs.compactMap { ($0 as? NSNumber)?.int64Value }
    guard !reportIDs.isEmpty else {
      return
    }
    let currentRunID = String(cString: runID)
    queue.async {
      for id in reportIDs {
        guard let crashReport = reportStore.report(for: id),
              isOrphanedHangReport(crashReport.value, currentRunID: currentRunID) else {
          continue
        }
        reportStore.deleteReport(with: id)
        AwsInternalLogger.debug("AwsKSCrashInstrumentation deleted orphaned hang report \(id)")
      }
    }
  }

  /// TC PATCH: see `observeHangReports`. A report KSCrash finalized as a recovered hang carries a
  /// `crash.error.hang` section and is never an orphan.
  static func isOrphanedHangReport(_ rawCrash: [String: Any], currentRunID: String) -> Bool {
    guard let report = rawCrash["report"] as? [String: Any],
          report["monitor_id"] as? String == "Watchdog",
          report["run_id"] as? String == currentRunID,
          let error = (rawCrash["crash"] as? [String: Any])?["error"] as? [String: Any] else {
      return false
    }
    return error["hang"] == nil
  }

  static func setupNotificationObservers() {
    // Update crash context on session start
    let sessionObserver = NotificationCenter.default.addObserver(
      forName: SessionStartNotification,
      object: nil,
      queue: nil
    ) { notification in
      if let session = notification.object as? AwsSession {
        queue.async {
          cacheCrashContext(session: session)
        }
      }
    }
    observers.append(sessionObserver)

    // Update crash context on user change
    let userObserver = NotificationCenter.default.addObserver(
      forName: AwsUserIdChangeNotification,
      object: nil,
      queue: nil
    ) { notification in
      if let userId = notification.object as? String {
        queue.async {
          cacheCrashContext(session: nil, userId: userId)
        }
      }
    }
    observers.append(userObserver)

    // Update crash context on screen change
    let screenObserver = NotificationCenter.default.addObserver(
      forName: AwsScreenChangeNotification,
      object: nil,
      queue: nil
    ) { notification in
      if let screen = notification.object as? String {
        queue.async {
          cacheCrashContext(session: nil, userId: nil, screenName: screen)
        }
      }
    }
    observers.append(screenObserver)
  }

  static func cacheCrashContext(session: AwsSession? = nil,
                                userId: String? = nil,
                                screenName: String? = nil) {
    var userInfo: [String: Any] = [:]

    // user
    let userId = userId ?? AwsUIDManagerProvider.getInstance().getUID()
    userInfo[AwsUserSemvConv.id] = userId

    // session
    let sessionManager = AwsSessionManagerProvider.getInstance()
    if let session = session ?? sessionManager.peekSession() {
      userInfo[AwsSessionSemConv.id] = session.id
      if let prevSessionId = session.previousId {
        userInfo[AwsSessionSemConv.previousId] = prevSessionId
      }
    }

    // screen
    if let screen = screenName ?? AwsScreenManagerProvider.getInstance().currentScreen {
      userInfo[AwsViewSemConv.screenName] = screen
    }

    reporter.userInfo = userInfo
  }

  /// Report cached crashes from KSCrash store (just a local file)
  static func processStoredCrashes() {
    // Init
    guard let reportStore = reporter.reportStore else {
      AwsInternalLogger.debug("AwsKSCrashInstrumentation no report store available")
      return
    }

    // Pull crash reports
    let reportIDs = reportStore.reportIDs
    for reportID in reportIDs {
      guard let id = reportID as? Int64,
            let crashReport = reportStore.report(for: id) else {
        AwsInternalLogger.debug("AwsKSCrashInstrumentation failed to load crash report \(reportID)")
        continue
      }

      // TC PATCH: see isUnperceivedUnexplainedTermination.
      if isUnperceivedUnexplainedTermination(crashReport.value) {
        AwsInternalLogger.debug("AwsKSCrashInstrumentation skipped unexplained background termination \(reportID)")
      } else {
        // Report crash as log event
        reportCrash(crashReport: crashReport)
      }

      // Delete processed report
      reportStore.deleteReport(with: id)
    }

    AwsInternalLogger.debug("AwsKSCrashInstrumentation processed \(reportIDs.count) stored crashes")
  }

  /// TC PATCH. KSCrash 2.6's Termination monitor injects a SIGKILL report, with no threads, for any
  /// previous run that did not exit cleanly and was not a crash, hang, OS/app upgrade, reboot or
  /// resource kill. iOS never tells a suspended app it is being killed, so every app-switcher swipe and
  /// every reclaim of a suspended app lands here as `termination_reason: "unexplained"`. Drop those
  /// when the app was not user-perceptible; keep memory/thermal/CPU/battery and foreground terminations.
  ///
  /// KSCrash counts `startup`/`launching` as perceptible because a tapped launch is, so a process the
  /// system launched in the background (task role not FOREGROUND_APPLICATION) and killed before it ever
  /// reached the foreground is dropped too.
  static func isUnperceivedUnexplainedTermination(_ rawCrash: [String: Any]) -> Bool {
    guard let error = (rawCrash["crash"] as? [String: Any])?["error"] as? [String: Any],
          error["termination_reason"] as? String == "unexplained",
          let appStats = (rawCrash["system"] as? [String: Any])?["application_stats"] as? [String: Any],
          let userPerceptible = appStats["user_perceptible"] as? Bool else {
      return false
    }
    if !userPerceptible {
      return true
    }
    let preForeground = ["startup", "launching"].contains(appStats["app_transition_state"] as? String)
    let taskRole = appStats["task_role"] as? String
    return preForeground && taskRole != nil && taskRole != "FOREGROUND_APPLICATION"
  }

  /// Report a KSCrash report in Apple format
  private static func reportCrash(crashReport: CrashReportDictionary) {
    let rawCrash: [String: Any] = crashReport.value
    let log: any LogRecordBuilder = logger.logRecordBuilder()
      .setEventName(AwsCrashSemConv.name)

    var attributes: [String: AttributeValue] = [
      AwsCrashSemConv.type: AttributeValue.string("crash"),
      // When `recovered_context` is true, then the following original attributes will be recovered,
      // and the crash event will be backfilled to the original session.
      // 1. `session.id`
      // 2. `session.previous_id` (if any existed)
      // 3. `user.id`
      // 4. original `timestamp`
      AwsCrashSemConv.recoveredContext: AttributeValue.bool(false)
    ]

    // Attempt to recovert the original crash context
    attributes = recoverCrashContext(from: rawCrash, log: log, attributes: attributes)

    // Get stack trace in Apple format and emit log event in async callback
    // If the iOS application was built with `strip styles` set to `debugging symbols`, then KSCrash will
    // also perform on-device symbolication.
    CrashReportFilterAppleFmt().filterReports([crashReport]) { reports, _ in
      var appleFormatReport = (reports?.first as? CrashReportString)?.value ?? "Failed to format crash report"
      if appleFormatReport.utf8.count > maxStackTraceBytes {
        appleFormatReport = String(appleFormatReport.utf8.prefix(maxStackTraceBytes)) ?? appleFormatReport
      }
      attributes[AwsCrashSemConv.stacktrace] = AttributeValue.string(appleFormatReport)

      // Prints the location of the first frame for the thread that crashed. For example,
      // `Crash detected on thread 0 at libswiftCore.dylib 0x000000019ed5c8c4 $ss17_assertionFailure__4file4line5flagss5NeverOs12StaticStringV_SSAHSus6UInt32VtF + 172`
      attributes[AwsCrashSemConv.message] = AttributeValue.string(extractCrashMessage(from: appleFormatReport))

      _ = log.setAttributes(attributes)
      log.emit()
    }
  }

  /// Get exception code information for the crash message. This is useful for grouping
  static func extractCrashMessage(from stackTrace: String) -> String {
    let lines = stackTrace.components(separatedBy: "\n")

    // Get exception type
    let exceptionType = lines.first(where: { $0.hasPrefix("Exception Type:") })?
      .replacingOccurrences(of: "Exception Type:", with: "")
      .trimmingCharacters(in: .whitespaces) ?? "Unknown exception"

    // Fallback to thread and first frame
    guard let crashedLine = lines.first(where: { $0.range(of: #"Thread \d+ Crashed:"#, options: .regularExpression) != nil }),
          let threadMatch = crashedLine.range(of: #"Thread (\d+) Crashed:"#, options: .regularExpression),
          let crashedIndex = lines.firstIndex(of: crashedLine),
          let firstFrame = lines.dropFirst(crashedIndex + 1).first(where: { $0.hasPrefix("0   ") }) else {
      return "\(exceptionType) detected at unknown location"
    }

    let threadNumber = String(crashedLine[threadMatch]).replacingOccurrences(of: #"Thread (\d+) Crashed:"#, with: "$1", options: .regularExpression)

    // Extract module and offset (skip instruction pointer which is unique per crash and breaks grouping)
    // Frame format: "0   ModuleName   0x00000001dccb1658   0x1dccab000 + 26200"
    //                    ^module      ^instruction pointer  ^base addr   ^offset
    let frameComponents = firstFrame.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    guard frameComponents.count >= 4,
          let module = frameComponents.dropFirst().first,
          let offset = frameComponents.last else {
      return "\(exceptionType) detected on thread \(threadNumber) at unknown location"
    }

    return "\(exceptionType) detected on thread \(threadNumber) at \(module) + \(offset)"
  }

  /// If sessionId and timestamp can be recovered, then attempt to restore original context.
  /// However, if user session context cannot be recovered, then we use the current timestamp
  /// and let sessions/user id processors do their work. For this edge case, users can look
  /// at the current `session.previous_id` to see if the previous session had crashed.
  static func recoverCrashContext(from rawCrash: [String: Any],
                                  log: LogRecordBuilder,
                                  attributes: [String: AttributeValue]) -> [String: AttributeValue] {
    guard let report = rawCrash["report"] as? [String: Any],
          let timestampString = report["timestamp"] as? String,
          let timestamp = timestampFormatter.date(from: timestampString),
          let userInfo = rawCrash["user"] as? [String: Any],
          let sessionId = userInfo[AwsSessionSemConv.id] as? String else {
      _ = log.setTimestamp(Date()) // just for clarity (upstream already does this)
      AwsInternalLogger.debug("AwsKSCrashInstrumentation failed to recover crash context")
      return attributes
    }
    var mutatedAttributes = attributes

    // required attributes for recovery
    _ = log.setTimestamp(timestamp)
    mutatedAttributes[AwsSessionSemConv.id] = AttributeValue.string(sessionId)

    // `user.id` is only nice-to-have for crash recovery, so we will grab it without blocking the overall recovery attempt
    if let userId = userInfo[AwsUserSemvConv.id] as? String {
      mutatedAttributes[AwsUserSemvConv.id] = AttributeValue.string(userId)
    }

    // `screen.name` is also nice-to-have, and may not exist if a screen had not been registered at the time
    if let screenName = userInfo[AwsViewSemConv.screenName] as? String {
      mutatedAttributes[AwsViewSemConv.screenName] = AttributeValue.string(screenName)
    }

    // `session.previous_id` is also nice-to-have, and may not even exist if there was no previous session
    if let previousSessionId = userInfo[AwsSessionSemConv.previousId] as? String {
      mutatedAttributes[AwsSessionSemConv.previousId] = AttributeValue.string(previousSessionId)
    }

    // Confirms that original context was recovered, since this may not be obvious
    mutatedAttributes[AwsCrashSemConv.recoveredContext] = AttributeValue.bool(true)
    return mutatedAttributes
  }
}

/// TC PATCH: pairs KSCrash's Started and Ended notifications for each hang, keyed by the hang's start
/// timestamp. Called from the watchdog thread and the main thread.
///
/// A hang only starts once the previous one's notifications have all been delivered (the watchdog thread
/// delivers Started, and a new hang needs both that thread and a fresh main run loop wake), so entries for
/// earlier hangs are dropped when a later one is seen. That bounds the table to the current hang, including
/// hangs that only ever get one notification: KSCrash skips Started when a hang ends before its report is
/// written.
final class HangNotificationPairs {
  private let lock = NSLock()
  private var seen: [UInt64: HangChangeType] = [:]

  /// True when this is the second of the Started/Ended pair for the hang that started at `startTimestamp`.
  func isSecond(_ change: HangChangeType, startTimestamp: UInt64) -> Bool {
    guard change == .started || change == .ended else {
      return false
    }
    lock.lock()
    defer { lock.unlock() }
    seen = seen.filter { $0.key >= startTimestamp }
    if let first = seen[startTimestamp], first != change {
      seen[startTimestamp] = nil
      return true
    }
    seen[startTimestamp] = change
    return false
  }
}
