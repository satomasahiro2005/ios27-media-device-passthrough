# iOS 27 Media Device Passthrough

A small, complete Media Device Extension for iOS 27. It puts one device named
**Passthrough** in the route picker. When the user picks it, the system hands this code the
audio other apps are playing, as samples. The sample runs them through a one-pole low-pass
filter and plays them on the built-in speaker, so you can hear that the audio really went
through your process.

The behaviour described below was measured on a device running iOS 27, in the app this
sample was extracted from. The notes that cost the most time to find are the ones about
entitlements, endpoints, now playing and video.

```
Spotify / YouTube / another player
  |   user picks "Passthrough" in Control Center
extension   MediaDevice + AudioServerPlugIn      receives the samples
  |   TCP 127.0.0.1:47101, float32 interleaved, 2ch, 48 kHz
app         AVAudioEngine                        filters and plays
  |
built-in speaker
```

## Two processes

The extension's sandbox denies everything that creates or waits. Writing into the App Group
container is `deny file-write-data`, POSIX shared memory is `deny ipc-posix-shm-read-data`
and `ipc-posix-shm-write-create`, and a listener is `deny network-bind local:*:0`.
Connecting out is allowed, which is the framework's own use case: send audio to a receiver
on the network.

So the waiting end lives in the app and the extension dials it. That is the whole reason
this repository has two targets rather than one. There is no shared ring buffer, no file
drop and no loopback inside the driver.

## The entitlement trap

Signing the **app** with a non-empty `com.apple.developer.media-device-extension` stops it
from opening an `AVAudioSession`: every category fails with `'!pla'`. The decision is
`-[MXCoreSession hasMediaDeviceEntitlement]`, and its only input is the entitlement on the
app process's own signature. Not the presence of an embedded `.appex`, not any Info.plist
key. `_CMSUtility_FetchSessionEntitlements` raises the flag only when the array is
non-empty.

So the app here carries no entitlements at all — `Sources/App/App.entitlements` is an
empty dict — and the protocol identifier lives only in
`Sources/Extension/Extension.entitlements`. If you later submit to App Store Connect, add
the key back to the app **with an empty array**: the store check (ITMS-91183) wants the key
present when an app embeds a media sharing extension, and an empty array leaves the runtime
check false, so audio still plays.

### Getting the entitlement

`com.apple.developer.media-device-extension` is not on by default and you cannot add it
from Xcode. Your App ID needs the **Media Device Sharing Extension** capability enabled in
the developer portal, and the provisioning profile has to be regenerated afterwards.
Without it the extension target fails to sign with

```
Provisioning profile "..." doesn't include the com.apple.developer.media-device-extension entitlement.
Provisioning profile "..." doesn't include the Media Sharing Extension capability.
```

The app target signs fine on its own, so a build can get surprisingly far before this
shows up. Apple grants the capability for alternative distribution; expect to have that in
place before the extension will sign.

## Required endpoints

`MediaOutputDevice(requiredNetworkEndpoints:)` must name an endpoint that exists and can be
reached. Port 0 — what you get from `NWEndpoint.Port.any`, or from an `NWListener` inside
the extension, which always fails because of `network-bind` — gets the route handed back to
the speaker about 1.5 seconds after the user picks it, with
`AVOutputContextDeviceConnectionFailureReasonMDERouteRevertedToLocal`.

The endpoint you name is the one the extension actually connects to: it is the TCP link
that carries the samples to the app. The system reads it as part of deciding whether the
route is permitted, so it has to be real either way. This extension names the port the app
is already listening on, `127.0.0.1:47101`.

## The protocol description is registered at boot

`UTTypeDescription`, in the extension's `UTExportedTypeDeclarations`, is not only a label.
Change it to a string the device has not seen before and the pick fails the same way a bad
endpoint does: the route reverts after a second or two. **It keeps failing until the device
is rebooted.** Changing it back to a string the device already registered works immediately,
without a reboot.

Measured on one device (iPhone 16, iOS 27.0) by changing that one string and nothing else:

| description | known to the device | pick |
| --- | --- | --- |
| `48 kHz, 32-bit float` | registered at last boot | works |
| `[DEBUG]` | new | reverts |
| `48 kHz, 32-bit float` again | known | works, no reboot |

This is easy to misread, because **the new string does show up**. It is the second line
under the device name in Control Center, and it appears in the failure dialog, which reads
`"<device name>" with <description>`. Seeing your new text there says the bundle was
installed, not that the route will connect.

In a device log the failure is indistinguishable from the endpoint problem above:

```
mediaremoted: Response: SetOutputDevices.perfrom<…> returned with error
  Code=28 "Adding or removing devices from the AV output context has failed."
  … in 2.0224 seconds          # a working pick returns in 0.05–0.3
→ [RoutingTimeline] .failed(…, resolution:.cancelFutureForItem(…))
```

The extension process still launches and registers as `media-device-discovery-extension`,
then stays silent — it is never activated. Whether you are in this state is easiest to tell
from your own sample-delivery log line: count it per minute and it is simply absent.

**This matters for shipped updates.** If a release changes this string, every user who
installs that update gets a device that will not connect until they reboot, and nothing in
the UI suggests rebooting. Treat the description as fixed after the first release, or accept
that the update needs a reboot to work.

`UTTypeIdentifier` is a different thing: changing that really does replace the registration,
and the device disappears from the picker entirely.

## Now playing

Do not claim playback with `MPNowPlayingInfoCenter` in the app.
`_CMSUtility_UpdateRoutingContextForSession` asks
`_CMSUtility_SessionCanBeAndAllowedToBeNowPlayingApp`, and when the answer is yes it moves
the session into the SystemMusic routing context and calls
`updateRouteSharingPolicy:setByClient:` with `(1, 0)` — LongFormAudio, set by the system,
not by you.

`AVAudioSessionTypes.h` says every application on the long-form policy has its audio routed
to *the same location*. Once that location is your own virtual device, the app's output
goes back into the extension and around again: the level meters rise and the speaker stays
silent. Measured across sessions opened by the app: with now playing declared, 1 of 5
sessions opened on the virtual device; with it off, 0 of 6.

There is no way out once it has happened. `overrideOutputAudioPort(.speaker)` returns
success and leaves the route on the virtual device (3 attempts, no change), and
`AVAudioSessionRouteSharingPolicyIndependent` is documented as not settable by an
application. Note also that while things are working the app's own route reads `Speaker`;
the virtual device is a *system* output, not this app's output, so `currentRoute` naming it
is the symptom, not the goal.

## Video on screen

If the app that is playing has video on screen at the moment the device is picked, the
system routes elsewhere.
`-[MXCustomRoutingController modifyCurrentSelectionIfNecessary:isPlayingVideoOutput:]` logs
`isPlayingVideoOutput: YES`, then `playing video or a long-form-video app. Will attempt to
switch to AirPlay`. With no AirPlay receiver in range the discovery times out after a
hard-coded 1.5 seconds (`fmov d0, #1.50000000` inside
`_discoverAirPlayRouteDescriptorsWithRouteUUIDS:forDiscoverer:`) and the route falls back to
local.

Spotify's Canvas, the short looping video behind some tracks, is enough to trigger it. Same
build, same app: 3 of 3 picks during a Canvas track were reverted, 2 of 2 during a track
without one stuck. Nothing the extension declares changes this — the branches that let a
session through are read from the *playing* app's bundle
(`MDESupportsUniversalURLPlayback`, `allowsExternalPlayback == NO`) or from the presence of
a MusicVAD.

The check runs only at activation. In one connected session that took 69 Now Playing
updates, the decision ran 0 times. So pick the device while no video is on screen; a Canvas
track starting afterwards does not interrupt anything.

## Driver contract

`AudioServerPlugIn.h` constrains what a media device extension may publish: a single output
device, and a transport type of `kAudioDeviceTransportTypeRemoteStreaming` or
`kAudioDeviceTransportTypeRemoteScreen`. Anything else fails registration with
`kAudioHardwareIllegalOperationError`. The device's `kAudioDevicePropertyDeviceUID` must be
the same string as `MediaOutputDevice.id`.

That id has to be a constant. Discovery and activation can run in separate processes, so an
id minted per launch puts two rows in the picker and neither one connects.
`kAudioDevicePropertyZeroTimeStampPeriod` has a documented minimum of 10923 frames; this
driver uses 16384.

Publish the audio device from `activateDevice`, before sample delivery starts. If no audio
device appears promptly after activation the system deactivates it again and the user sees
"Unable to Connect".

## Buffers

System audio arrives in `DoIOOperation` at the `kAudioServerPlugInIOOperationWriteMix`
stage, as one interleaved float32 stereo buffer — the stream's ASBD is packed, 8 bytes per
frame. The link carries it in that form. The app side is the other convention: an
`AVAudioSourceNode` on the standard format renders into a planar buffer list, `mBuffers[0]`
for left and `mBuffers[1]` for right, so the de-interleave happens in the app.

`DoIOOperation` is `CA_REALTIME_API`, which is `[[clang::nonblocking]]`. Under ARC, reading
a strong static into a local emits `objc_retain` and `objc_release` in that function, and
the release can take a side-table lock. The sample handler is therefore held in an
`_Atomic(void *)` and read `__unsafe_unretained`.

## Wire format

Each chunk is a 12-byte header — an 8-byte magic and a 4-byte sample count — followed by
float32 samples, L and R alternating, little-endian, at most 2048 frames. TCP does not
split on 4-byte boundaries. Dropping or resending the 1 to 3 leftover bytes that `send` and
`recv` return makes every later float straddle two samples, which reads back as NaN, 1e38
or a denormal and never resynchronizes.

Both ends keep the remainder in bytes and verify the header on every chunk. The link is
written against BSD sockets rather than Network.framework so that a sandbox denial names
the system call that was refused.

## Process lifetime

`AudioServerPlugInRegisterMediaDeviceExtension` has no unregister counterpart, and calling
it with NULL arguments crashes instead of unregistering. This extension ends its own
process on `deactivateDevice`, so the next activation is a first registration in a fresh
process.

Do not leave on the same turn as the call. During activation the system takes a
`MediaDeviceDiscoveryOrBridge` assertion on the extension process; if the process is
already gone it logs `RBSAssertionErrorDomain Code=2 "Specified target process ... does not
exist"`, counts it as an activation failure and evicts the protocol from
`MXCustomEndpointCache`. The picker row then spins and the cached device is dropped.

## Building

You need macOS with Xcode 27, a device running iOS 27, Apple Developer Program membership
and `xcodegen`. The `.xcodeproj` is generated from `project.yml` and is not tracked.

```
brew install xcodegen
xcodegen generate
```

`project.yml` deliberately has no `DEVELOPMENT_TEAM`, so pass yours on the command line:

```
TEAM_ID=XXXXXXXXXX bash Scripts/build.sh
```

Change the bundle identifiers from `ai.nemut.mdepass` to your own, and pick a protocol
identifier. It has to match in three places: the array in `Extension.entitlements`,
`UTTypeIdentifier` in the extension's `Info.plist`, and `protocolType` in
`PassthroughExtension.swift`. The entitlement value is an array with one element; a bare
string stops the extension from launching.

Run the build from a Terminal inside the Mac's own GUI session. Over SSH the app compiles
and links but the `.appex` fails to sign with `errSecInternalComponent`, and the install
then reports "not a valid bundle" — the failure does not say anything about signing.

Reinstalling in place is fine. Deleting the app and installing it again leaves the old VA
port registered in `audiomxd` with no way to remove it, and the next pick reports
"Unable to Connect" until the device is rebooted.

Device only. `MediaDevice.framework` ships in the iPhoneOS SDK and not in the simulator
SDK, so the extension target does not link for the simulator and no audio flows there.

## Using it

Launch the app first and leave it running. It owns the listening socket, and the extension
can only connect outwards — if the app is not there, the pick fails.

Then play something, open Control Center, and choose **Passthrough** as the output. Audio
from the playing app arrives at the extension, crosses the link, and the app plays it back
through the low-pass filter. Pick it while audio is actually playing; see
[Video on screen](#video-on-screen) for what happens when it is paused or showing video.

## Logs

`Logger.info` does not reach `idevicesyslog`; use `.notice` or the line is simply absent.
Interpolated values are redacted by default, so anything you want to read back needs
`privacy: .public`. Both mistakes look identical to a bug in your code.

The lines that explain a failed pick come from `audiomxd` and `mediaremoted`, not from the
extension. Useful strings to grep in a device log: `customEndpoint_Activate`,
`modifyCurrentSelectionIfNecessary`, `Going to deactivate endpoint with name=`, and
`MDE fallback to local`.

`Going to deactivate endpoint` appears on normal disconnects too. The line above it tells
you who did it: `preprocessPickEndpoint ... clientPID=0` is the system reverting the route,
while a `clientPID` belonging to `mediaremoted` with `initiator=RoutePicker` is a person
picking a different output.

## Layout

| path | what it is |
| --- | --- |
| `Sources/Extension/PassthroughExtension.swift` | advertises the device, handles activation, starts sample delivery |
| `Sources/Extension/MDPDriver.h` / `.m` | the AudioServerPlugIn that receives WriteMix |
| `Sources/Extension/Info.plist`, `Extension.entitlements` | extension point, protocol identifier |
| `Sources/Shared/LocalLink.h` / `.m` | the TCP link, sender and receiver in one file |
| `Sources/App/PassthroughApp.swift` | the one screen: link state and a cutoff slider |
| `Sources/App/AudioIO.swift` | session, engine, source node, route handling |
| `Sources/App/LowPass.swift` | the filter — replace this with your own |
| `Sources/App/Info.plist`, `App.entitlements` | app keys; the entitlements file is empty on purpose |
| `project.yml` | the XcodeGen spec both targets come from |
| `Scripts/build.sh` | generate, build, install, with the traps above baked in |

The app target is deliberately thin: replace the filter with whatever you want to do to
the samples.

Comments in the source are in Japanese.
