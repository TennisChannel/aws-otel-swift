# Tennis Channel fork

Fork of [aws-observability/aws-otel-swift](https://github.com/aws-observability/aws-otel-swift),
used by `apps/tc-mobile` in TennisChannel/TennisChannel.

Each `tc/<upstream version>` branch is the upstream tag plus one commit. Its
release tag is `<upstream version>-tc.<n>` (`1.1.0-tc.1` = upstream `1.1.0` +
patch, first revision).

## The patch

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
git cherry-pick <patch commit from the previous tc/ branch>
git tag <new>-tc.1 && git push origin tc/<new> <new>-tc.1
```

Then point `apps/tc-mobile` at the new tag (project + workspace
`Package.resolved`).

## Retiring

Switch `apps/tc-mobile` back to upstream once aws-otel-swift filters these
reports or exposes KSCrash's monitor configuration.
