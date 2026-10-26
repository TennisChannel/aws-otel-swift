# Tennis Channel fork

Fork of [aws-observability/aws-otel-swift](https://github.com/aws-observability/aws-otel-swift),
used by `apps/tc-mobile` in TennisChannel/TennisChannel.

Each `tc/<upstream version>` branch is the upstream tag plus the patches below,
one commit each. Its release tag is `<upstream version>-tc.<n>` (`1.1.0-tc.1` =
upstream `1.1.0` + patch, first revision).

## Patch: URLSession delegate classes

`telemetry.network.delegateClasses` in `aws_config.json` names the URLSession
delegate classes to instrument; it is passed to opentelemetry-swift's
`URLSessionInstrumentationConfiguration.delegateClassesToInstrument`. Marked
`TC PATCH`.

Without it, `URLSessionInstrumentation` finds delegate classes by calling
`objc_getClassList` and copying the method list of every class in the process
(~78k on iOS 26). The agent initializes from `+load`, so that scan runs before
`main` on every cold start: 435-684 ms in a Release build on an M-series
simulator, against ~50 ms for the rest of the agent's init. Leaving the key out
keeps upstream behavior.

## Patch: KSCrash unexplained terminations

`AwsKSCrashInstrumentation.processStoredCrashes` drops KSCrash reports whose
`crash.error.termination_reason` is `"unexplained"` and whose
`system.application_stats.user_perceptible` is false, marked `TC PATCH`. A
follow-up commit also drops unexplained reports still in `startup`/`launching`
whose `task_role` is not `FOREGROUND_APPLICATION`: a process the system launched
in the background and killed before it reached the foreground. KSCrash counts
those states as perceptible because a tapped launch is; a tapped launch keeps the
foreground role and still reports.

KSCrash 2.6 added a Termination monitor, on by default, that writes a threadless
SIGKILL report for any previous run that ended without a clean exit and was not
a crash, hang, OS/app upgrade, reboot or resource kill. A suspended iOS app gets
no notice before it is killed, so every app-switcher swipe and every reclaim of a
suspended app arrives as a crash (`0 (SIGKILL) detected at unknown location`).
aws-otel-swift 1.1.0 was built against KSCrash 2.4.0, which predates the
monitor, but allows any 2.x, so apps resolve 2.6 and forward these as
`device.crash`.

## Patch: foreground-only hangs

`AwsHangInstrumentation` counts main-thread time toward a hang only while the
app is in the foreground, marked `TC PATCH`. `willResignActive` and
`didEnterBackground` end the counted part of the current run loop pass, no pass
starts counting while the app is away, and `willEnterForeground` or
`didBecomeActive` starts counting again from that moment.

Upstream times every pass from `afterWaiting` to `beforeWaiting` regardless of
app state. In Tennis Channel prod data, about half of all `device.hang` spans
were the pass that takes the app out of the foreground (a system-only FrontBoard
scene-update wait), and most of the rest of the long ones ran while the app was
backgrounded (background audio, PiP, background launches). Two passes blocked
when the user left were suspended mid-pass and reported as 40-minute and 3.8-hour
hangs. None of these is visible to the user.

## Upgrading

```
git fetch https://github.com/aws-observability/aws-otel-swift.git --tags
git checkout -b tc/<new> <new>
git cherry-pick <each patch commit from the previous tc/ branch>
git tag <new>-tc.1 && git push origin tc/<new> <new>-tc.1
```

Then point `apps/tc-mobile` at the new tag (project + workspace
`Package.resolved`).

## Retiring

Drop a patch once upstream covers it: the KSCrash one when aws-otel-swift
filters these reports or exposes KSCrash's monitor configuration, the URLSession
one when it exposes `delegateClassesToInstrument` or stops scanning at `+load`,
the hang one when upstream stops counting time the app is not in the foreground.
Switch `apps/tc-mobile` back to upstream when none are left.
