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
`system.application_stats.user_perceptible` is false, marked `TC PATCH`.

KSCrash 2.6 added a Termination monitor, on by default, that writes a threadless
SIGKILL report for any previous run that ended without a clean exit and was not
a crash, hang, OS/app upgrade, reboot or resource kill. A suspended iOS app gets
no notice before it is killed, so every app-switcher swipe and every reclaim of a
suspended app arrives as a crash (`0 (SIGKILL) detected at unknown location`).
aws-otel-swift 1.1.0 was built against KSCrash 2.4.0, which predates the
monitor, but allows any 2.x, so apps resolve 2.6 and forward these as
`device.crash`.

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
one when it exposes `delegateClassesToInstrument` or stops scanning at `+load`.
Switch `apps/tc-mobile` back to upstream when none are left.
