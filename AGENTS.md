# DeskMote

## Release approval

Start publication only after the user explicitly approves release. The `Release` workflow creates a draft internally to attach the verified ZIP. Apply the checks below before a publication run, including prereleases, retries, and recovery.

1. Resolve the release candidate to its full commit SHA. Use `master` for a new release and the release tag for recovery. Find the standalone `CI` runs in this repository for that exact SHA. If none exists, dispatch `ci.yml` at the ref that resolves to the candidate.
2. Wait for `CI` to finish and review every run and attempt for that SHA, including earlier attempts. Publish only when the history is available and every run, attempt, and required test step completed successfully. A skipped, cancelled, missing, or unknown result blocks publication. A test failure permanently disqualifies the SHA, even after a successful rerun. Use a new commit and require its own passing `CI`.
3. Recheck the `master` SHA immediately before dispatching publication. For recovery, resolve the tag again. The `Release` workflow verifies the tag immediately before publishing.

Use the repository's default branch, `master`, for explicitly authorized direct commits. Preserve the expected branch head when updating the ref. A new release request includes the reviewed source, documentation and release manifest in the candidate commit. Keep its publication separate from standalone CI.

## Environment

- Build for macOS 27 or later and Apple silicon. Use Xcode 27.2 (27B52), Swift 6, Git, Python 3 and Node.js.
- Use the GitHub Actions `xcode-27` runner. The scripts select the same Xcode locally and in CI. Set `DEVELOPER_DIR` to its `Contents/Developer` only if installed at another path. Make that Xcode the command-line default on hosted runners so child processes launched by XCTest select the same toolchain.
- Keep `README.md` and this file as the repository’s Markdown files.

- Run all local tests outside the sandbox, including Xcode tests, standalone test binaries, Python unit tests and Node test suites. Escalate the specific test command. Run signing, packaging and static checks in the sandbox.
- For DeskMote builds on Xcode 27.2 (27B52) that export `Resources/AppIcon.icon`, run the Xcode build command outside the sandbox. The sandboxed `actool` export fails with `Icon export exited with status 255`. Check the Xcode version and whether the build exports the icon before escalating the build command.

## Architecture to preserve

- The DeskMote target owns the taskbar, cross-application window operations, menu bar icon and login registration. Use actual `SMAppService.mainApp` status for the menu checkmark. A reopen restores the same status item.
- Register optional modules in `DeskMoteModuleRegistry.production(registerWindow:)`. The empty registry also starts the core. Keep Command Shift, Natural Switch and Battery Run as separate Swift targets. Enable input modules only after a successful start, stop them on disable, and restore saved selections at launch.
- Register shown utility windows through the shared callback. Read their state and execute window actions through AppKit. For visible utility windows, use `NSWindow.isOnActiveSpace` for taskbar visibility even while Space membership reads are catching up. Retain the last AppKit-confirmed Space for minimized and hidden utility windows until the membership read agrees. Keep DeskMote excluded from external window discovery. Exercise minimization, closure, reopening, display and Space routing with registered and unregistered windows.
- Use Accessibility as the app’s privacy permission. The core needs it for windows and Command Shift uses it for the event tap. Keep the core taskbar pointer-driven and leave Apps search text input to AppKit. Do not add core keyboard handlers, input taps or tests that post or forward key events. Command Shift retains its own shortcut and existing event semantics. Natural Switch follows external mouse presence while enabled and leaves the last direction in place on disable.
- Give each extension an independent target and embed phase entry. Use `DeskMoteWidgetBundle` to add widgets. Retain the air quality widget’s kind, intent type and input parameter names for installed instances. Give the widget the sandbox and HTTPS client entitlements. Finder Sync captures the folder and file type and submits them to its embedded XPC service. Authenticate both peers against their installed code signatures and let the service perform exclusive creation. Preserve numbered names and a valid ZIP with an empty folder.
- Keep app identifiers stable. Verify the graph alongside the package because an excluded extension or library can otherwise return as an implicit Xcode dependency.

## Maintenance

Use DeskMote’s history and release tag archives to identify the source corresponding to distributed binaries. Use reverse engineering to establish behavior from the exact native binary or reference build. Implement the behavior independently with DeskMote's license. Keep research binaries, third-party code, reference captures and personal observations outside the repository.

Use the following procedure for fixes.

1. Identify the affected subsystem, the last known working revision and the first build with evidence. When reporting a defect, lead with whether there is a supported fix and its runtime cost. Distinguish observations, hypotheses and confirmed causes.
2. Add a regression test and make the smallest applicable change.
3. Preserve DeskMote's open-window model and module boundaries.
4. Check the diff for launchers, unrelated file operations, Dock changes and extra settings. Limit the Finder service to the two file creation commands and protect the existing taskbar behavior.
5. Complete [automated verification](#build-and-verify) on the exact candidate source and hand off the locally signed full Dev build.
6. Record the affected behavior, reasoning and verification in the commit message.

Restoring a removed feature requires an explicit scope decision and review of its models, services, views, resources, project references and tests. Keep commits focused and explain the change, its reason, the preserved behavior and the verification. Follow SOLID, KISS and DRY. Review and test nontrivial changes before publishing directly to `master`.

Maintain the macOS 27 deployment floor across all targets. Use the pinned stable Xcode, with matching Swift 6 settings, for local and CI builds. Verify the Xcode version and build number. Update the runner and Xcode together when changing the supported toolchain. Keep Python and Node.js on stable releases. Record the effective macOS, Xcode, Swift, Python and Node versions in build logs for toolchain investigations. Pin official GitHub Actions to full release commit SHAs and check CI before accepting an update. If Dependabot is configured for Actions, use its daily schedule and the same CI gate. Use macOS system frameworks and keep the application, packaging and release flow free of third-party runtime packages.

### Artifact storage and recovery

The workflow retains the single `DeskMote` app artifact for seven days. Use GitHub Actions job logs for test and build failures. Preserve a failed release's verified ZIP until normal expiry so publication can resume.

Any authorized artifact cleanup must run its policy checks before obtaining Actions write access, use trusted `master` code and ignore fork or pull-request completion events. Apply the policy after CI or Release completes and when the policy changes. Keep the three newest completed artifacts per managed name and the newest successful result, including any legacy `test-results` and `xcodebuild-test-log` artifacts still present. Preserve active, triggering and unknown runs and unrelated artifacts. Limit deletion to Actions artifacts. Release assets, tags, source, runs and logs stay intact.

After `Re-run all jobs`, a resume must match successful validation and the versioned build with failed publication in the verified attempt. Use the single `DeskMote` artifact created during its successful upload step. Download by artifact ID and check its recorded digest. Stop on missing, expired or ambiguous artifacts, or a mismatched tag revision.

### Dev diagnostics and performance

Build Debug with `DESKMOTE_VARIANT=full` and bundle identifier `io.github.sashokey.deskmote.dev`. Keep the release bundle name `DeskMote.app` and display name `DeskMote`. Sign the app and embedded bundles locally with an ad hoc signature. Use a reduced variant only when explicitly requested. Set each embedded target's bundle identifier under the Dev app's namespace and use the matching Finder XPC service name. Verify that the full Dev app links Command Shift, Natural Switch and Battery Run, and that the signed bundle contains both app extensions and the Finder XPC service. Keep both production and Dev self-identities out of inventory and helper ownership. Enable `DOCK_INVENTORY_LOG` and `DOCK_CLICK_TRACE` only for an agreed diagnostic run. Collect their bounded journals from one instance in the Dev app's local log directory.

Use `ActionResourceLog` for Dev action and native-call intervals. Record elapsed time, process CPU time, CPU percentage relative to one core, and physical footprint before, after and as a delta. Overlapping actions share process counters. Use the signpost `trace-id` to align Instruments GPU time and utilization with the action. Record unavailable GPU metrics as unavailable when the system cannot attribute them to AppKit actions. Compile the measurement and its call sites out of Release.

Compare the same configuration, diagnostics, display setup, windows and interval lengths. Mark idle, window switching and Space switching separately. Compare Release with Release when isolating runtime cost. Replay the same events before and after a change and count actual AX, WindowServer and Space calls separately from queued work, including failed attempts and size writes. The 100-move regression removes two extra full AX reads and two full WindowServer captures. The 30-event same-destination Space replay uses one in-flight read and one latest pending read. These are controlled test counts.

For an incident, correlate the app version and source revision, process and boot, permission or lifecycle transition, native return code, window identity, display and Space. Capture app and system logs for the relevant process and time interval, including the previous build and boot when available. Installing a new build does not by itself erase unified logs. Distinguish a native exit from a crash, a rejected effect from an unconfirmed effect, and a missing log from a missing event. Repair missing evidence at the existing boundary before adding calls. Keep diagnostic data local.

## Build and verify

```sh
bash Scripts/test.sh full
bash Scripts/test.sh base
bash Scripts/build.sh full
bash Scripts/build.sh base
bash Scripts/build.sh no-widget
bash Scripts/build.sh no-finder
python3 -m unittest discover -s Scripts -p 'test_*.py'
node --test Scripts/check_release_workflow.mjs
python3 Scripts/check_localization.py
python3 Scripts/check_debug_switches.py
```

The full app contains `DeskMoteWidgets.appex` and `DeskMoteFinder.appex`. The two exclusion builds contain only the other extension. The base build contains neither extension and builds without the three optional Swift targets. Each build verifies the application, deployment target, revision, architecture, versions, nested signatures and entitlements. The full test command also runs module, widget, Finder file-creation and WindowLab tests.

CI tests and verifies the full and base variants from the same commit. The reusable workflow verifies the archived app after extraction and uploads only the full ZIP as the `DeskMote` artifact. Automated tests use injected inventory, window actions, permission, and system settings boundaries to avoid real window and Accessibility access.

### Extended core checks

Run coverage and the constrained Swift executor for nontrivial core changes. Keep DerivedData and XCTest data in a location accessible to the runner, such as a temporary directory. When checking deployment availability, run `Scripts/check_availability_warnings.py` on the relevant test, build and WindowLab logs. Retain logs and result bundles on failure. Use the build script for the arm64 Release checks and `Scripts/package_release.sh` to verify the archive when changing packaging.

```bash
set -euo pipefail
source Scripts/lib/xcode.sh
require_deskmote_platform
select_deskmote_xcode
verify_dir="$(mktemp -d /tmp/deskmote-core-checks.XXXXXXXX)"
build_args=(
  -project DeskMote.xcodeproj -scheme DeskMote -configuration Debug
  -derivedDataPath "$verify_dir" -destination 'platform=macOS,arch=arm64'
  -parallel-testing-enabled NO DESKMOTE_VARIANT=full CODE_SIGNING_ALLOWED=NO
)
xcodebuild test "${build_args[@]}" -enableCodeCoverage YES \
  -resultBundlePath "$verify_dir/Tests.xcresult" 2>&1 | tee "$verify_dir/test.log"
xcrun xccov view --report --json "$verify_dir/Tests.xcresult" > "$verify_dir/coverage.json"
python3 Scripts/coverage_summary.py "$verify_dir/coverage.json"

suites=(
  InventoryLifecycleTests AppTrackerPeriodicBatchTests AppRuntimeTests
  WindowCommandLifecycleTests WindowObservationLifecycleTests
  AppIconResolverTests PanelLifecycleTests
  TaskbarSpaceStoreTests TaskbarBehaviorTests WindowHeightAdjustmentTests ApplicationBehaviorTests
  AppTrackerDisplayAttributionTests ActionResourceLogTests
)
only=()
for suite in "${suites[@]}"; do only+=("-only-testing:DeskMoteTests/$suite"); done
TEST_RUNNER_LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 \
  xcodebuild test-without-building "${build_args[@]}" "${only[@]}" -enableCodeCoverage NO \
  -resultBundlePath "$verify_dir/Constrained.xcresult" 2>&1 | tee "$verify_dir/constrained.log"
python3 Scripts/check_availability_warnings.py "$verify_dir/test.log" "$verify_dir/constrained.log"
```

Report line coverage for `DeskMote.app` alone. Test sources and duplicated application sources in the test target are outside the application coverage metric. Assert the actual end effect for every core flow.

## Release

Publish changes directly to `master`. Use `vN` as the Git tag, release title, displayed version and ZIP version. Start at `v1` and increase `N` by one at every release, including corrections. The application and both extensions use `N.0.0` for `CFBundleShortVersionString` and `N` for `CFBundleVersion`.

1. Set `version`, `draft`, `prerelease` and `notes` in `.github/release.json` on `master`. Cover all shipped changes since the last published tag in the notes. Use `[skip ci]` in the candidate commit to suppress push-triggered publication. Set `draft: false` for publication and use `draft: true` when the user asks for a draft.
2. Dispatch standalone `ci.yml` on the candidate and complete [Release approval](#release-approval). Verify that the version has no existing tag or release. If a push-triggered `Release` started, cancel it before it creates a tag and verify that publication has not begun.
3. Dispatch `release.yml` on verified `master` with inputs `version`, `prerelease` and `draft`. Pass `draft: false` for a public release. Use the configured GitHub connector for reads. If it lacks dispatch or cancellation, use the fallback GitHub MCP `actions_run_trigger` with `run_workflow` or `cancel_workflow_run`.
4. Verify the successful `Release` run, the tag's exact SHA, the published release, and its single asset `DeskMote-vN.zip`. For a failed publication, retry the failed jobs or use `resume_run_id` when the retained artifact, tag, and original release request match.

Keep the release tag at the tested commit from creation through the workflow's final verification. Defer any separate operations on that tag until publication finishes. GitHub checks the ref and writes the release in separate requests. If publication fails, check the tag and release before retrying.

Run this from a checkout with the repository configured as `origin`, using the published tag.

```sh
tag=v1
release_checkout="../DeskMote-$tag"
git clone --branch "$tag" --single-branch "$(git remote get-url origin)" "$release_checkout"
cd "$release_checkout"
release_revision="$(git rev-parse --verify "refs/tags/$tag^{commit}")" &&
local_app="$(bash Scripts/build.sh full --local "$tag")" &&
test "$(plutil -extract DeskMoteSourceRevision raw -o - "$local_app/Contents/Info.plist")" = "$release_revision" &&
printf '%s\n' "$local_app"
```

Local and CI builds use the same Xcode, compiler options and ad hoc signature. The script signs the extensions before signing the app and verifies that `DeskMoteSourceRevision` in `DeskMote.app/Contents/Info.plist` matches the checkout commit. For the published ZIP, compare the same key in the extracted app with `git rev-parse --verify "refs/tags/$tag^{commit}"`. Keep the local copy on the Mac.

## Taskbar reference and boundaries

Use public AppKit and SwiftUI components for UI construction and rendering. Keep private SkyLight calls confined to native window and Space integration.

The UI reference is Windows 11 Pro 26H2 (26300.9711), 1920×1080 at 100%, dark theme, Small taskbar, bottom, left aligned, with combining set to When taskbar is full and window buttons shown on the taskbar where the window is open. Use the live UI and Microsoft's current taskbar settings for this reference. The historical Win32 guide documents the Windows 7 taskbar. [Current Windows taskbar settings](https://support.microsoft.com/en-us/windows/experience/personalization/customize-the-taskbar-in-windows) · [Windows 7 design guide](https://learn.microsoft.com/en-us/windows/win32/uxguide/winenv-taskbar)

Use two physical displays for the multi-display reference. Static analysis of the Windows 11 ARM64 and x64 images and the matching reference DLLs confirms Small's 32 DIP height, 16 DIP icons, and separate hover, pressed and active states. An ISO supplies binaries for static analysis. Use the configured reference captures for rendered measurements and interaction evidence.

Retain only the open-window area. The observed taskbar height is 32, button height 28, top/bottom inset 2, icon size 16, and Start's outer left inset 10. Translate these to macOS points, not unscaled Retina pixels. Use the macOS system font and native app icons. The bar fills the screen width and touches its bottom edge.

Render the latest accepted window title on the next presenter update, including rapid tab changes and intermediate application titles during chat navigation. Do not freeze captions based on how often they change or wait for a quiet interval. Keep unread Accessibility titles distinct from known empty values. A failed read may preserve the last known title, while a successful read must reach the native button without an artificial hold.

A follow-up measurement kept five Terminal windows, two File Explorer windows, and fifteen Notepad windows separate in a 1,676-pixel button area. Compressed long buttons painted at 74–75 pixels with 2-pixel gaps. Adding another Notepad window combined Terminal. A short Clock caption painted at 66 pixels while space was available. A separate Windows Terminal window titled exactly `.` used a 39-pixel button and a 41-pixel pitch to the next icon. The label starts at 28 with an 8-pixel trailing inset. Keep natural caption width separate from the compression limit, and distribute fractional width across buttons without accumulating empty pixels. These are measurements of the configured reference, not Microsoft-documented universal constants.

Right-click actions use AppKit NSMenu and ordinary NSMenuItem rendering. Build the shared app menu from its common controls and available module sections. The base menu is Open at Login, Hide Status Bar Icon, a separator, and Quit. Internal reordering moves the existing button views within the taskbar. It must not create a detached system drag image. Use those same constrained group bounds to select an insertion position: the leading edge crosses a left neighbor's midpoint or the trailing edge crosses a right neighbor's midpoint. Do not require the pointer to enter another button. Compare with complete neighboring groups and their current layout slots, keeping the result stable during animation and repeated pointer events. Returning to the original slot must not persist a reorder. Hover and active transitions respect Reduce Motion. Keep the Windows-shaped neutral highlight and lower active underline/inactive dot. Do not replace them with an accent-filled macOS toggle or pill shape.

In the Windows reference, inactive hover and unhovered active have similar body fill. Active has a stronger edge and a longer colored indicator. Hovering active increases its fill and softens its edge. Holding a press darkens it. Preserve those distinctions with native neutral selection and separator colors over the Apple material, not an opaque accent fill or a hover that overrides active. A settled lossless capture measures the active underline at 11 by 2 pixels, one pixel above the button bottom. Translate this to points. The inactive indicator remains 4 by 2. Keep its horizontal center exactly aligned with the 16-point icon. An 11-point underline needs a half-point left coordinate at 1x. Rounding that edge shifts its center. Preserve the dimensions and vertical placement, and verify the rendered centers at 1x and 2x. An immediate transition frame is not evidence of its final width.

The taskbar and combined/overflow list use Apple's public [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview), with content inside `contentView`. Buttons compose public NSButton, NSTextField, NSImageView, and NSBox controls: AppKit draws the controls, while DeskMote supplies the measured Windows geometry and interaction state. The highlight uses `unemphasizedSelectedContentBackgroundColor`, with the original four-point corner radius and no filled accent color. Only the lower active indicator uses the system accent. Do not layer separate Liquid Glass surfaces on the buttons. Use the text field's alignment rectangle to retain the measured label insets rather than adding its intrinsic margins to them. Center that rectangle vertically on the icon and visible button, and use native backing-pixel alignment rather than rounding to whole points. At 2x the 15-point line is centered exactly. At 1x retain AppKit's nearest-pixel placement. Do not center on the enlarged bottom-edge hit target. The list uses NSTableView, native row selection, NSScrollView, and standard symbol close buttons over the glass. Keep all intervening backgrounds clear. The permission-recovery hint uses a SwiftUI GroupBox. Do not restore private glass selectors, a separate fake blur layer, or the former floating capsule/resize grip. Preserve existing window tracking, native tabs, display attribution, fullscreen visibility, and maximized-window avoidance.

The status icon uses public [NSStatusItem.isVisible](https://developer.apple.com/documentation/appkit/nsstatusitem/isvisible) with the stable autosave name `DeskMote.StatusBarIcon`, so AppKit preserves visibility across launches. Do not reset visibility on startup or ordinary activation. Handle [Finder reopen events](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:)) by showing the existing status item and returning false to suppress default window creation. Reopening an already running installed app restores the icon and its saved visible state without restarting the taskbar. Keep transient-install guidance unchanged.

No thumbnails or screen capture are allowed. A separate button has no hover popup. Combined groups and overflow use only window titles and application icons, including during file dragging. Closing the popup cancels pending row actions. ScreenCaptureKit and Screen Recording permission must not be reintroduced for these lists.

During a group drag, keep the committed order as the priority for combining buttons while moving their live layout slots to the proposed position. Recompute the priority after committing the move. A resize or inventory change can still remove the dragged button and cancel the move.

Accessibility remains necessary for window management. App Sandbox is incompatible with the retained cross-application Accessibility operations. See [Apple's restrictions](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox). Do not add privacy permissions to solve unrelated implementation issues. Derive core fullscreen visibility and taskbar routing from window and Space state. The optional Command Shift tap runs only for its own input-source shortcut. Treat window titles and diagnostic reports as potentially sensitive. They must not be uploaded automatically.

## Apps launcher

Keep the visible Start-shaped Apps button inset and extend both hover and clicks to the physical lower-left corner at 1x and 2x. Keep the taskbar for open windows. Pinned apps and folders belong inside Apps. Preserve Search, its text entry and results, and the existing menu interactions. Exclude Windows system-tray, taskbar pins, window thumbnails, and the native macOS Apps recommendation section from the design.

In Pinned, dropping one app onto another creates a folder. Dropping onto a folder adds the app. Dropping between tiles reorders them. Preserve stored pins, folder contents and order independently of changes to All. Keep a bundle-path fallback for a previously pinned app when the catalog changes. In List, use the same app artwork representation as Pinned and scale it to the row size. The smaller system representation can contain a different border or treatment.

All follows the system Apps catalog. Query the Spotlight application index within the catalog roots and apply the system visibility resource value `_NSURLIsHiddenBySystemKey`. Preserve native display names and stable identity. Application package type and background-only flags alone are insufficient. If indexing or visibility fails, keep the last valid All catalog if one exists and surface the compatibility notice. Keep Pinned, other catalog views and Search usable. Avoid shipping a hardcoded machine-specific application list.

The lower running-app row uses system application identity. Resolve Finder from system bundle metadata and reserve its leading slot outside the running scroller, even when its process is absent. For a running app with a bundle URL, use the native application-open/reopen action so an app such as Finder can open a window. Keep the running indicator and context actions tied to live state.

Reuse one prepared `AppsMenuView` per panel, releasing its cache when the display disconnects. A cold click shows the container before loading the catalog. Reset search and transient menu state on reuse. Keep the 190 ms opening and closing animations and Reduce Motion. During the slide, move the prepared view vertically, hit-test its visible portion using the current position, and reverse from that position if it closes early. Cover cold/warm opening, in-motion click, closing and reopening, and isolate catalog fixtures from shared preferences.

## Permission startup and recovery

On a normal installed launch without Accessibility permission, remain an accessory application and request only the native system prompt. Poll for the grant without opening a DeskMote guide or repeating the prompt. Elapsed time, an initial denial, or an ungranted permission is not proof of a broken permission record. A late grant starts the taskbar once in the same process. Quitting while waiting prevents a later grant from starting it.

Keep explanations for transient or read-only installations, sustained permission loss after startup, and failed recovery relaunches. Preserve the permission-loss debounce, panel suspension, recovery guidance, and retry behavior. Do not reset privacy permissions or introduce new ones to test first-launch behavior. Use injected permission states for automated checks.

### Critical Accessibility revocation incident

Removing Accessibility from a running Dev build was followed by a session-wide input freeze. The cursor still moved, but clicks and key presses had no effect. The freeze was already visible when the lid was opened. The journal records TCC deleting the grant and the same DeskMote process requesting the AX server 21 seconds later. It contains no matching lid-open event or stack trace that establishes the cause of the whole-session freeze. A separate revocation report had an AppKit termination event and no crash report. Preserve the termination source and recovery path in Dev logs.

Stop new core AX IPC on the first negative permission sample or native `apiDisabled` error. Keep the permission probe independent of the main thread and the existing debounce for recovery UI. Test with injected failures and a blocked main thread. Reproduce live removal only in an isolated macOS instance where a frozen session can be reset independently.

## Embedded helper windows

An embedded accessory process may own a visible window while a regular application provides its identity. Admit that helper only when exactly one running regular host contains its canonical bundle below Contents, both executables remain inside their own bundle's Contents/MacOS directory, and both processes have valid Apple-anchored signatures with the same Team ID. Verify code identifiers and process generations. Unknown, ambiguous, unsigned, mismatched, or escaped paths do not establish ownership. Do not add application-name exceptions or privacy permissions.

Keep the native window PID, bundle origin, generation, AX element and CG identity. Use the verified host only for presentation/grouping and ordinary Quit, validating both identities before Quit. Window activation, minimize, restore and close still target the native owner. Cache the binding after admission. Reuse existing focus/event refreshes and remove it on helper or host termination and tracker shutdown. Signing checks run during background admission, not rendering or focus polling.

Recheck the live foreground when accepting family focus evidence. When the verified helper itself is frontmost and system AX focus is unread, accept a fresh local `AXFocusedWindow` only for the exact accepted PID, generation, AX element and CG window. Give a successful system AX result priority. Use one active window selection for all panels and for click planning. Retire stale activation predictions when their commands are superseded or fail, and keep an eligible Close handoff while a newer activation is pending.

AX lists may expose another process's elements. Skip confirmed foreign owners rather than relabeling them. Unread ownership is a failed inventory read, not confirmation that windows disappeared. Independently switchable nonmodal AXDialog windows require a confirmed application-level parent and a reasonable frame. Sheets, modal dialogs, unknown dialog metadata and floating utility windows remain excluded.

## Custom application windows

Inventory merges an application's published window list with its focused and main window elements. A failed whole-list read remains unknown. A successful empty list does not discard separately published roots. Validate native ownership and retain the exact AX element for window commands.

A substantial AXWindow with AXUnknown subrole can be an independent window. Require a confirmed nonmodal application parent and the same-owner, normal-layer WindowServer root. A nonempty title or exact window focus supplies initial positive evidence. An already admitted independent root can continue without either, while retaining its native ownership, parent and modal guards. Main-window capability is not required. Existing application, utility, system, transparency and geometry exclusions still apply. Missing parent or modal data does not establish eligibility.

A filtered window that remains in raw AX is not an absent tab. Preserve independent seats when focus or title evidence changes. Apply newer confirmed focus before eligibility. A confirmed native child loses its independent seat without a destroy tombstone. Missing native metadata preserves prior inventory and a detached root can be discovered again.

## Menu-bar application windows

A standalone accessory application can own ordinary switchable windows even though it has no Dock icon. Do not exclude its whole process based on activation policy. Check each window with the same title, frame, role, subrole, transparency, and system-surface rules as other applications. Embedded helpers must satisfy the verified ownership rules above.

Keep an admitted application's AX observer after its last window closes, just as for regular applications. The open-window projection hides the empty application. An AX window-created event must detect its next window without waiting for periodic admission. Process termination and tracker shutdown still release the observer. Do not restore the former non-regular eviction retries, which implemented obsolete Dock-style app-card behavior.

## Window lifecycle and quiet-state guarantees

The runtime snapshot contains actual windows only. Keep admitted application observers for future window-created events, but do not synthesize app-only cards or retain per-process read generations after termination. A departed process loses its pending read token. A reused PID receives a fresh token, so late results cannot consume its new request.

Land each completed AX read and release its PID before reading the next application. A slow application must not hold another application's ready result or trailing event. Coalesce pending snapshot publication on the main queue without adding a timer. A newer immediate rebuild supersedes the queued publication. Reuse one immutable application-candidate list per ownership pass, but revalidate each helper and host generation and signature before accepting its binding.

Skip the full CG list on launch retries with an empty or unread AX result. Use a fresh managed Space layout to decide panel visibility independently of window membership. Desktop shows the panel immediately on its display. Full Screen and Split View hide it on that display. An older fullscreen CG image cannot override a confirmed Desktop return. Request one targeted refresh through existing inventory and show the returning window button when its current membership is confirmed. Diagnose layout confirmation, panel show and button projection as separate stages. The old path delayed the panel by about one second while waiting for stale fullscreen evidence.

Use ordinary AppKit Space collection behavior and transient Mission Control hiding. The removed service-Space `pin` often reported `spaceNotVisible` while AppKit already showed the panel. Keep it out of the panel and popup lifecycle. Native Dock preferences and placement remain under macOS and the user.

Use workspace and AX notifications for inventory and focus updates. Refresh the affected process or window. Keep the system-focus check for tracked helper families. Schedule zero recurring window or Space reads in a settled session. Preserve focused-window identity when a stale command or blocked read finishes.

Keep one inventory backoff and the latest coalesced event per process generation. Resume deferred work when the next applicable event arrives. An unread round preserves the last confirmed inventory.

Read minimized state, title, position, size, role, and subrole in one AX attribute batch per window. Preserve individual AX errors. Use scalar reads for unsupported batches or ambiguous fields within the original budget. Apply the inventory backoff after a batch timeout.

Queued AX subscription removal belongs to its observation session. Stopping that session cancels pending cleanup, releases its queued elements, and prevents the next native removal from starting. An already admitted call may drain. Retiring an element from a live session still removes all required notifications. Release phantom-held diagnostic episodes when their seats retire. Admission history used only by tests is Debug-only. Runtime diagnostics use the bounded inventory log rather than unconditional console dumps.

Read managed layouts and targeted window memberships off the main actor. A blocked membership read must allow panel visibility to update. Check Space generation and window identity before accepting results. On an unverified Space ABI or malformed system result, suspend affected projections and show one diagnostic notice per error code with the event, macOS and source revision. Find the corresponding unified log entry in taskbar-spaces.

Keep panel visibility, window membership and exact confirmed focus as independent facts. The panel projects them by physical display and active Space. An activation request alone cannot light the active indicator. Preserve the last confirmed result through a transient unread focus sample when its identity is still current. Use typed failure handling for native API changes. Notices must identify the failed operation and reason, affected feature, relevant event and platform/build context so the matching Dev trace can be found.

Keep the per-window Space membership read authoritative in Release and in Debug verification mode. Use `DOCK_SPACE_BATCH_MODE=verify` to compare per-Space results in runtime diagnostics before enabling the batched path. Cover moved, minimized, hidden, fullscreen, and shared-Space windows in automated tests. Retain scalar lookup for parked windows and missing results. Discard the capture when its layout changes or its read budget expires.

During a group drag, reuse text measurements and move only the dragged frames while the insertion slot is unchanged. A combined/overflow list stores window models and asks NSTableView for reusable rows near its viewport. Cancel a removed row's delayed file hover before reuse, and rebind its title, selection and exact-window actions.

The focused-window observer uses the shared AX observation session, with messaging timeouts on each individual AX element. Create and register off the main actor. Attach and detach the run-loop source on it. Coalesce refreshes and retargeting, cancel obsolete operations, and reject callbacks from older lifecycles. A transient focused-window read preserves the last confirmed registration. Retry unavailable subscriptions on Space changes and when switching applications.

An unresolved application icon can be cached between renders, but application launch/activation invalidates that unresolved result. Notify the presenter so the existing button refreshes even if the window inventory did not change. Keep successful icons cached and perform file-stamp checks off the main actor.

## Window height and native Fill

`WindowHeightAdjustment` consumes geometry independently of inventory and panel rendering. Use the actually visible, unoccluded Small panel frame for the same display and active Desktop. Read the exact focused window once per geometry operation. Require both vertical edges to match `NSScreen.visibleFrame` exactly and require overlap. Shorten to the panel top with one immediate `AXSize` write, preserving position and width. Skip own, minimized and fullscreen windows. Leave the resulting size on quit.

`AXWindowMoved` and `AXWindowResized` report geometry. Native Fill from the green-button menu or a configured title-bar double-click remains owned by macOS. The same exact geometry from a resize qualifies. Ordinary refocus of an existing window only establishes a baseline. Evaluate an already exact first frame once when AX creation or launch focus proves it belongs to a new window. Keep creation evidence tied to that first frame. Discard obsolete completion after focus, binding, layout or geometry changes using local state. A notification caused by the size write and duplicate frames must not repeat it. Keep `DOCK_WINDOW_LIFT=0`. The removed tiling heuristics, geometry tolerance, animation, timers, automatic retries, extra pre-write AX read and quit restoration stay out of this path.

Cold launches such as Slack can open directly at the qualifying height. In the PhpStorm incident, early observation and focus reads returned `kAXErrorCannotComplete` and inventory found the window before focus was confirmed. Keep the remaining existing launch attempts alive until the current window's focus can be established. Use the already obtained focus and first-frame evidence. Keep the new-window rule independent of app names and avoid additional recurring work.

Moving the system Dock can reserve space on one display and cause WindowManager to expand an already filled window on the display it leaves. A custom tiler can choose its own target frame but does not change native Fill's contract. Native tiling state and geometry are distinct, and the investigation found no dependable external completion notification for the stock gesture. Preserve the geometry rule. With drag-to-top, macOS can report intermediate frames, retile after a successful size write, or report a top edge different from the selected working area. Do not widen tolerance, change focus-only behavior, or add retry/timing guesses without new evidence and scope approval. In Dev, correlate `window-height` notification, binding and layout revision, display and work area, the full frame before `AXSize`, result, and the next already-scheduled AX read. That next read is a later observation.

## Inventory and action identity

For a previously tracked native root, keep one in-flight movement operation and its latest pending event. Reuse a current CG capture if available. Otherwise query only that window's description and current native parent, with a narrowly scoped visibility fallback when metadata is missing. Preserve exact AX element, CG ID, PID, process generation, current root/layer/alpha guards, display-motion confirmation and independent title/minimize/creation handling. Never relabel a full capture with a newer timestamp. Every authoritative geometry writer must share freshness, including when an older read would retire a record as a foreign owner, child, absent root or different tab.

Keep window Space membership authoritative for confirmed transfers, including transfers within one display. Ordinary and transfer queries share per-window freshness. Coalesce the same identity and destination to one active and one latest pending query. Keep unrelated windows independent and let a new destination supersede a blocked old destination. Require tests for `A → B → A`, late ordinary and full reads, tab switch or child conversion after movement, and blocked work while the relevant display changes.

A matching frame or size does not establish that two minimized windows are native tabs. Keep independent windows at startup. Retain positively observed tab membership and shadow evidence. A visible tear-out needs an unambiguous old seat and a replacement without its own independent seat. Minimized members are not visible tear-outs. Keep every physical seat token stable and every CG ID unique in the ordered inventory.

Treat a failed CoreGraphics capture as unknown for destructive decisions. Preserve AX-absent seats, histories, shadow evidence and cached handles until a successful CG capture confirms absence. Positive AX updates may still land in that round, including an unambiguous visible switch to a previously observed tab member without its own independent seat. Geometry alone cannot establish a replacement while CG is unknown. A successful empty capture remains different from a failed one.

Application observer readiness includes its application-level subscriptions, not only an allocated AX session. Retry temporary creation and registration failures on the next applicable event using the subscription backoff. Keep established window subscriptions and reject results from a stopped generation. Record unsupported notifications and retain supported subscriptions.

An open combined/overflow list must invalidate its rows and delayed actions when their process, CG or action identity changes, even when the stable seat ID is unchanged. A separate button's delayed file hover must capture and validate the original identity, then allow a fresh hover after rejecting a stale target. A title-only update may update the existing rows. Preserve external window titles literally, including a window whose title is exactly `DeskMote`.

Keep the command identity tied to the accepted AX element when a process reuses a CG ID. A replacement element invalidates queued commands while retaining the visual seat. Compare any acquired AX target to the captured element before sending the window command.

After restore, publish the executor's already confirmed exact focus to inventory when the original action and identity are current. A temporary AX read failure must not leave the restored window inactive in the click planner. That caused repeated activation instead of minimizing on the next Slack click. Verify restore followed by minimize without an intervening focus switch and reject late focus from superseded commands.

Keep the removed duplicate SkyLight activation out of restore. For the deferred Chrome restore issue, the recorded flash affected web content for one frame after the animation. The frame remained visible to WindowServer and the native Dock control had no flash. `window-restore` traces cover both minimized windows and hidden apps with the action, native commands and related visibility/focus. Existing evidence does not establish a cause. Use that boundary when revisiting the issue.

Taskbar buttons and window lists use pointer actions. Right-click opens the native context menu. A clicked list stays open until dismissal or another deliberate action. Pointer exit uses the existing grace period for hover and file-drag lists. Clicking cancels pending hover from other groups, and later hover cannot replace a clicked list.

Destructive tab inference and phantom cleanup require current native-root, raw-AX absence, subscription identity and AX/Space evidence. A failed read is unknown. Keep live minimized windows and windows assigned to another Space. A minimized-at-startup window can be independent even when it has never been seen visible. Preserve positively learned tab membership. Phantom cleanup also requires a matching current sibling frame so an unrelated window does not become a shadow tab.

Close can supersede a pending activation or minimization of the same window. Repeated Close remains coalesced while its accepted operation is pending. Confirm helper activation against the exact system-focused native window when its verified host remains frontmost, revalidating the host generation and bundle origin.

At dequeue, check a panel action against the Space revision and visible window representative from its original panel. Discard commands that lost their projection before native execution and clear their pending feedback.

A Space notification also cancels in-flight panel actions before their next native effect and allows calls already started to drain. When a new Space is confirmed with a partial window read, hide windows with unconfirmed membership. Keep previously confirmed membership for the same parked window and require fresh membership when a replacement AX target inherits its CG ID.

Save canonical application keys alongside the same-boot window order. Reconstruct application ranks from those keys when a new tracker assigns different seat serials. Retain the existing missing-window grace and new-boot reset. Session-local serials are not persistent application identities.

## Verification and regression policy

Tests describe the agreed behavior and independently observed reference scenarios. A failing assertion is a reason to investigate the implementation, not to weaken the expectation. Change an expectation only when the requirement or verified reference behavior changes, and explain why in the commit.

Use RED → GREEN → REFACTOR for behavior changes: first run a regression test and confirm that it fails for the reported defect, then implement the smallest correction and run the complete suite. A compilation error is not evidence that the test detects the defect. Refactor only while the behavior tests remain green.

Keep fixture setup and test-only helper methods in test sources. Replace external AX, WindowServer, and application lookup operations at their boundaries. Exercise the production controllers and assert their resulting state, requested operations, or rendered content. Derive expected values independently of the implementation. Use isolated defaults for catalog fixtures. AppKit forwards unsupported synthetic Return or Space through its responder chain and can beep. Exercise the pointer path and native Search text behavior through injected or offscreen controls.

### Automated checks

Run the verification commands above. CI runs the full and base test suites, checks deployment availability, builds arm64 Release products and verifies the ZIP, signatures, identity, rights, deployment target and checksum. Preserve failed test and build logs. Use the extended commands for coverage and constrained-executor regression checks.

Use the pinned Xcode for local builds and tests. Repeat native checks on the available supported macOS. Keep DerivedData and XCTest runtime data in a location Xcode can access. A background test runner may be denied access to a test bundle inside a protected Documents folder even when compilation succeeds. Do not change system privacy settings to work around this silently.

Keep test coverage for the following behaviors.

- Window identity, inventory admission, minimized/hidden retention, native tabs, activation, focus handoff, and permission recovery.
- Ordered window-command execution, cancellation between external operations, rapid minimize/activate replacement, independent close requests, and draining in-flight commands across runtime stop/restart. Tests assert external effects as well as published state.
- Background AX observer creation and registration, windows discovered during registration, stop or window retirement/replacement during a blocked call, subscription cleanup, and rejection of late callbacks from a replaced session.
- A confirmed managed layout drives panel visibility. Missing layouts suspend affected projections. Test Desktop return during a blocked membership read, typed diagnostic failures, stale results, and quiet-state call counts.
- Current-Space filtering per display, fullscreen-window removal from its former Desktop, shared Spaces, retained minimized-window membership, failed Space reads, coalesced background reads, stop/restart, and preserved manual order. Combined close actions only contain windows on the visible Space. Display-only inventory changes refresh the affected window membership. Two offscreen presenters exercise transfer in both directions. Rapid transfers coalesce, stale reads cannot overwrite current membership, and same-display geometry/title/focus changes do not trigger extra Space reads.
- Native transient panels hide in Mission Control. The active Space type determines whether the panel can appear afterwards.
- No-screen startup, display disconnect/reconnect, and separate handling of missing display UUIDs. Native panel creation is replaced in lifecycle tests so no window is shown.
- Bounded process-generation caching and cleanup after process termination.
- System-only initial permission prompting, continued waiting without a guide or repeated prompt, late grants, grants arriving during startup, and quitting before a grant. Confirmed runtime recovery and transient-install guides remain covered separately.
- Display attribution, topology changes, state-based fullscreen visibility, and clearance for focused windows that enter exact working-height geometry.
- Separate labeled buttons, content-sized short captions including the exact `.` reference, the measured 74-point compressed width for long captions, pixel rounding, combining under crowding, expansion after space returns, and accessible overflow.
- Whole-application group moves selected by the dragged leading/trailing edge crossing the neighboring group midpoint, unequal widths and different grab positions, stable repeated pointer events, round trips without persistence, preserved member order, mouse-up outside, and windows/apps or available width changing during a drag.
- No hover popup for separate buttons. Icon/title lists for combined groups and overflow only.
- Popup dismissal on its own window losing focus, own-view pointer/drag presence, and stale focus notifications from replaced panels.
- Native AppKit context-menu items and action dispatch, exact-window activation and close actions, Close all windows for a combined group, and Quit as a separate application action.
- File-drag hover activation, cancelled delays, stale targets, and list disposal.
- Detached AppKit rendering and input routing through an injected popup presenter. These tests must never display windows over the user's desktop or request screen capture. Native mouse-tracking checks may attach views to a panel that is never ordered on screen. Detached image rendering checks control geometry and content. It does not establish WindowServer glass refraction or transparency against the real desktop.
- Native controls with preserved icon/text alignment, neutral hover/active feedback, lower indicators, animated-state settling, Reduce Motion, transparent native list backgrounds, native table mouse tracking, pointer scrolling and exact-row close dispatch. Explicit line separators in captions render as spaces on the original single baseline, with width measured from that same visible text. Raster comparisons cover LF, CRLF, CR and Unicode line/paragraph separators at 1x and 2x in both appearances. The original title and Accessibility label stay intact. Independently compare caption pixels with a native Auto Layout centerY reference at real 1x/2x backing scales, including truncation, fallback glyphs and color emoji. Assert the shared visible panel center separately, including the 30-point hit target. The native 1x grid rounding must not become a whole-point rounding on Retina.
- The Windows state hierarchy, applied to both AppKit appearances: similar hover/active body fill, stronger active edge, stronger fill on active hover, and darker held presses. The active underline is 11 by 2 points with a one-point bottom gap. Its horizontal center must equal the icon center exactly, including at 1x where its left edge falls between pixels. Check both the view/backing geometry and the centers of the actually rendered icon and indicator at 1x and 2x. A half-pixel centering tolerance hides the defect.
- Bottom-edge hit testing and hover tracking at 1x and 2x, exact-window clicks, combined/overflow lists, file-hover activation, preserved horizontal gaps, and cancelled clicks outside the bar. Raster comparisons verify that larger hit targets do not change the 28-point visible buttons.
- Ordered common menu commands, sections driven by the installed modules, checked visibility toggling in both directions, native-restored visibility, icon restoration and independent login/quit actions.
- Launch-at-login state, localization, debug-switch registration, pinned toolchain selection, release publication, and verification of the artifact retention policy when changing it.

Coverage reports identify untested paths. A count or percentage alone does not establish correct behavior. Automated tests cannot establish real Accessibility interoperability, native WindowServer animation, or hot-plug behavior on every Mac.

### Main behavior integration

`TaskbarBehaviorTests` drives the production presenter, runtime, planner, command queue, action executor and AX reader against a stateful boundary for Accessibility, WindowServer and application operations. It checks minimize-to-restore without a CG entry, exact group/list and file-hover activation, close and combined close, ordinary Quit, rejected identities, failed confirmations, cancellation during handle capture, and persisted or cancelled group moves. Assertions include observed window state and resulting taskbar content. The executor itself is not replaced.

Title-update regressions replay repeated browser tab open/close titles and chat/application-name transitions through the production runtime and presenter into native button captions and Accessibility labels. Drain queued updates without waiting for a quiet interval. Assert each accepted title replaces its predecessor while the button identity and window order remain stable. Reader and inventory tests separately cover unread titles, known empty values and window replacement.

`WindowHeightAdjustmentTests` delivers focused-window Accessibility notifications through the production observer. Assert one size-only write on entry into exact working-height geometry, and cover duplicate events, another display, unavailable Accessibility, and no write while the destination panel is hidden.

`ApplicationBehaviorTests` enters through AppDelegate for first launch, late grants, reopen, permission suspension, recovery and termination. Replace native presentation and application/process operations so these checks never open windows, modify TCC, terminate other processes or change the user's desktop. Runtime, panel orchestration and permission coordination stay real.

When changing these paths, prove the corresponding regression test rejects a missing action or write: disconnected toggle/activate/close/reorder, omitted normal termination, unconditional command failure, skipped unminimize, skipped lift write, and skipped reopen icon restoration. A compilation failure does not count as detecting the regression. Run the complete suite after restoring the implementation.

Coverage summaries select the `DeskMote.app` target. Test sources and duplicated source copies belong outside the application metric. Tests must assert the end effect of each core flow. No aggregate line percentage establishes that contract.

### Runtime behavior

Use automated tests with injected Accessibility operations to verify candidate builds. Investigate issues observed in production using runtime diagnostics. The user manages DeskMote’s own macOS Accessibility permission. Never ask the user to grant macOS Accessibility permission to Codex or its tools.

#### Window-manager behavior

| Scenario | Expected result |
| --- | --- |
| First launch | Only the native Accessibility prompt appears. No DeskMote permission window or extra Dock presence. No Screen Recording request. |
| Initial permission still missing | Waiting, denial, and elapsed time do not open a guide or repeat the system prompt. A later grant starts the taskbar once without relaunching. Quit prevents a delayed startup. |
| Transient installation or confirmed recovery failure | Show the relevant explanation for the actual problem. Do not infer a broken permission record from initial waiting alone. |
| Embedded helper application | Steam has the main application icon/group. Activate, minimize, restore and close affect the selected native window. Quit terminates the main application normally. No extra permission request. |
| Independent settings window | Terminal Profiles appears alongside its main window and can be activated and closed. Its child modal sheet does not become a separate button. |
| Running app without windows | No launcher or pinned button appears. |
| Several windows of one app | Separate labeled buttons while space remains, adjacent in stable discovery order. |
| Activate, minimize, restore, rename, close, create | Surviving siblings keep their order. A new window joins its app group. |
| Crowding and freeing space | Long buttons shrink to the measured 74-point limit before combining. Short captions keep their content-sized widths. Groups separate again when space permits. |
| Group dragging and cancellation | The whole group stays inside the 32-point bar even when the pointer leaves it. A wide group swaps with a narrow neighbor when its edge crosses that neighbor's midpoint, regardless of which member or side was grabbed. Its members cannot be reordered independently. Release outside restores the original order. |
| Separate-window click | Activate/restore the exact window. Clicking the active window minimizes it. |
| Separate-window hover | Neutral Apple selection color within the Windows button shape. Hover must not overpower active: similar fill, stronger active edge and 11-by-2-point underline. Active hover increases fill, and held press darkens it. The lower inactive dot is 4 by 2. Both sit one point above the button bottom. No solid accent-filled button or nested glass. Smooth transitions. Immediate changes under Reduce Motion. No popup, tooltip, thumbnail, or extra title. |
| Combined-group click/hover | Native Apple rows over public Liquid Glass, with the preserved 216-point width, 40-point rows, icon/title/close placement, and window order. No captured window images. |
| Overflow | Remaining windows stay reachable through an icon/title list. |
| Click outside a window list | A clicked list closes when its own panel loses focus. Hover/drag lists use their own pointer-exit grace period. Taskbar dismissal uses AppKit focus and own-view events. |
| Individual context menu | Native macOS menu: Close window, then Quit. Closing a window does not quit the app. |
| Combined context menu | Native macOS menu: Close all windows, then Quit. Window actions affect the represented display's group. |
| Unsaved documents | Normal application confirmation is honored. Quit never force-terminates the target. |
| Finder file drag over a separate button | Delayed restoration/activation. Leaving early cancels it. DeskMote does not accept or open the file. |
| Finder file drag over a combined button | Open the icon/title list. Hovering a row restores that exact window so the file can be dropped into it. |
| Fixed bar geometry | Full display width, attached to the bottom, 32 points high. First button starts 10 points from the left. |
| Pointer at the bottom display edge | Buttons still highlight and respond to clicks, context menus, and file hover at the last screen pixel, including combined and overflow buttons. Visible button geometry stays at y=2, height=28. The extra two points are only an interaction area. Horizontal gaps and empty taskbar space remain background targets. |
| Retina, light/dark, accessibility display options | Geometry follows scale. System font and public Liquid Glass remain legible. |
| Background/menu-bar menu | Open at Login and Hide Status Bar Icon precede any installed module sections. Quit stays last and exits normally. The base menu has only the common controls. |
| Hide status icon and restart | The icon disappears while taskbar operation continues. The choice survives application restart and login/reboot. |
| Reopen the running app from Applications | The same status item reappears. Its visible state is saved. No second taskbar instance or new document window appears. |
| Open the taskbar menu while the icon is hidden | Hide Status Bar Icon stays enabled and checked. Selecting it restores the icon and clears the checkmark. Selecting it again hides the icon. Opening or refreshing the menu alone does not change visibility. Open at Login and Quit remain independent. |
| Fill on both displays | Fill from the green-button menu and configured title-bar double-click works for narrow windows and after restoring a smaller size. When both vertical edges match the working area, the window clears the visible panel while its top, left and width stay fixed. Resizing to the same edges follows the same rule. Quit leaves the resulting window size in place. |
| Two displays, Spaces and moving windows | Each bar shows windows on the current Space of that display, including minimized windows assigned there. Windows on other Spaces, including fullscreen Spaces, are omitted. Moving a window between displays in either direction updates its button on the destination without waiting for the periodic Space refresh. Unrelated buttons retain their manual order. Switching back restores the buttons in their manual order. Grouping and close actions use only the visible windows. |
| Mission Control from Desktop or fullscreen | The taskbar is hidden on both monitors by native AppKit transient-window behavior. On leaving Mission Control, it returns on regular Desktops and stays hidden on fullscreen Spaces. No input observation is used. |
| Disconnect/reconnect, sleep/wake | No stale panels, duplicate buttons, or inaccessible windows after attribution settles. |
| Fullscreen and Spaces transitions | The bar follows actual window/Space state and returns after the transition. Pending popups/actions are cancelled. A brief appearance during the transition animation is possible because input-based prehiding has been removed. |
| Accessibility revoked/restored | Panels and pending actions suspend safely. Core operation resumes after permission recovery. Automated tests inject trust changes and cover the optional shortcut module independently. |
| Native Dock | Its preferences and process remain untouched. |

For production failures, record OS, scale, display arrangement, version, source revision, steps and observations. In repository documentation, use de-identified information for examples and results. Exclude local account names, personal paths, dates and timestamps. Describe the user's computer only as a MacBook with Apple silicon.

#### Integration checks

| Scenario | Expected result |
| --- | --- |
| Start the base app with Accessibility and use the taskbar | Activating, minimizing, restoring and closing windows works. The status menu contains only its common commands. |
| Open the full status menu | `Open at Login`, `Hide Status Bar Icon`, `Input`, `Utilities` and `Quit` appear in order with the specified separators. Section headers do not respond to clicks. |
| Open `Show Battery Runtime Estimates` twice | The existing Battery Run window opens or comes forward. Its taskbar button appears on its display and Space. Reopening preserves a single button. |
| First launch and deny Accessibility when enabling Command Shift | Both input toggles start unchecked. Denial keeps Command Shift unchecked and the shortcut inactive. No Input Monitoring request appears. |
| Grant Accessibility and use `Use Shift–Command to Switch Input Sources` | Start succeeds, the checkmark appears, and the chord switches between configured sources. Disabling stops the action. |
| Toggle `Auto-Switch Scroll Direction` with an external mouse and trackpad | The enabled module selects the direction as devices change. Disabling stops updates. |
| Restart, then log out and back in with `Open at Login` enabled | Disable `Reopen windows when logging back in` before logging out. DeskMote starts and restores only enabled modules. The checkmark tracks system login registration. |
| Select `Hide Status Bar Icon`, then reopen DeskMote | The single status icon returns and the taskbar remains available. |
| Add the widget in `Edit Widgets` | The gallery lists both sizes. A new widget requests `Source URL`. A compatible HTTPS page produces current readings. |
| Toggle Finder File Creator in `System Settings → General → Login Items & Extensions → Extensions → By Category → File Providers` | Click ⓘ to see the switch. Right-click a local writable folder’s background. The two direct creation commands appear when enabled and disappear when disabled. `New Text Document` creates an empty `New Text Document.txt` and `New Compressed (zipped) Folder` creates a ZIP containing an empty folder. Neither opens a window or overwrites an existing item. |

### Accessory and embedded application admission

Run inventory lifecycle tests through the production activation-policy gate. A standalone accessory bundle with a standard Dashboard window remains eligible through seed, scan and launch retry. An embedded helper needs a unique, current host identity established by the production ownership resolver. Resolver tests replace only running-process, generation and signing boundaries. Exercise canonical component containment, symlink escape, executable containment, missing/mismatched signers, ambiguous hosts, and process replacement during verification. No application-name matching is used.

Verify the same helper inventory through seed, scan and launch retry, with ownership work off the main thread. Presentation uses the host identity while records retain the helper PID and origin. The real presenter/runtime/planner/executor/AX reader must minimize and restore the exact helper window, close only that window, and send normal Quit once to the current matching host. Changed host identities must block Quit. Host termination retires helper inventory and observers. Host-frontmost polling refreshes helper focus without repeating signature checks. Foreign AX elements are not assigned to the enumerating process. Unread ownership preserves prior inventory.

Exercise top-level nonmodal AXDialog settings windows through the real AX reader and inventory filter. Confirmed settings windows appear. Modal, unread, nested and floating utility surfaces do not. Closing and reopening a tracked accessory window must use its existing observer without an app-only card or a periodic-admission delay.

Mutation checks must detect removed signer equality, path containment, host generation validation, dialog boundaries and native AX ownership filtering. Keep mutation copies separate from the source used for release. Use production diagnostics for the AX roles that Steam and Terminal Profiles expose and the window commands they accept.

### Review regression coverage

Use the production lifecycle controllers with injected AX sessions and a monotonic clock. Keep the test views offscreen and do not revoke live Accessibility permission.

- For the geometry observer, cover blocked startup, registration and reads, rapid app and focus changes, stop, stale callbacks, transient errors, fallback recovery and bounded retries.
- For a long-settled session, assert zero fast per-window queries. Then fast probes include only transitioning windows and expire after the response interval. Verify event-driven refresh and fallback discovery of external geometry changes with a fake clock and counted probe calls.
- For inventory, closing the last window leaves no synthetic card and retains the application observer. Process churn releases mutation generations. A late response from an old process cannot consume a replacement process's in-flight read.
- For icons, unresolved lookup retries on launch and activation, repeated renders use the cache, resolver lifetime is independent of notifications, and icon recovery refreshes an existing button without an inventory update.

The constrained Swift-executor pass covers geometry observation, height adjustment and icons. Keep coverage for window order, native tabs, actions, rendering, display attribution, and permission recovery.

### Review regression boundaries

Hold a second application's periodic AX read and verify that the first application's ready title is published and its next event completes before releasing the second reader. Keep unread, stale-token, generation-replacement and stop coverage. Count running-application enumeration across an ownership batch with multiple helpers and a missing PID. Expect one candidate snapshot while host-generation changes and signature failures still reject bindings. A cancelled batch must not enumerate or check signatures.

Block one subscription removal, queue more, stop the observer and restart with a fresh session. After the admitted call drains, no further removal may target the old session. Live retirement still unsubscribes normally. Repeatedly retire phantom-held seats while their process survives and assert that diagnostic state returns to its live cardinality. Independent minimized startup windows must retain their seats without unconditional debug output.

Space observation tests must prove off-main layout and membership reads, independent panel visibility, and rejection of results from earlier lifecycle and Space generations.

Move a taskbar group repeatedly within one insertion slot and assert that unchanged icon/content work is not repeated. Scroll a long native list through a small viewport, verify bounded row reuse and exact activation/close targets, and cancel file-hover activation when its row leaves the viewport. Keep pointer activation, title-only refresh, rendered geometry and disposal tests on native cells obtained from the table rather than eager row storage.

Keep production-reconcile tests for overlapping independent windows, an independent window entering a vacated frame, same-size minimized startup windows, a positively observed native tab switched and minimized after moving, visible tear-out, and failed versus successful-empty CG captures. Failed captures must preserve cached handles and old histories while accepting positive AX changes, including a new window at a retained window's old frame and a known tab switch that preserves its original seat through CG recovery.

Observer tests must exercise nil factory recovery, transient application-level registration, already-registered and unsupported responses, preservation of established window subscriptions, and stop during blocked recovery. Unsupported is not an immediate-retry loop and does not establish complete event coverage.

For list identity, open both combined and overflow lists, change the CG/action target or process generation without changing the seat ID, and assert dismissal plus cancellation of stale file-hover and row actions. Reopening must target the replacement. Keep a title-only update open and actionable. Reject a separate button's stale pending file hover and allow a fresh hover on its replacement. For order persistence, create two real tracker lifecycles with different seat allocation histories. Also cover empty/partial startup snapshots, identity learning without a reorder, direct return after the absence grace without an intermediate sync, and a new boot. Verify an external window titled DeskMote retains its title through the real presentation path.

Review fixes additionally cover independent off-Space windows with the same frame under both existing-sibling and new-sibling admission order. Unknown and stale AX/Space/session evidence. Minimized-at-startup omissions and return without false tab learning. And positive dormant native-tab controls. Drive the existing bounded background probe path, including process replacement during a read.

Hold activation and minimization before their external effect, send Close for that same window, and verify only the replacement close executes after the admitted call drains. A duplicate Close must retain the original accepted operation. Confirm helper activation and restoration through the production executor's return value as well as native state. Periodic feedback reconciliation must not mask a false result.

Clicked combined and overflow lists survive pointer exit without focus loss. Hover and file-drag lists retain their exit grace. Clicking a group cancels a previous group's delayed hover, and further hover cannot replace the clicked list. Preserve native focus-loss dismissal and exact row actions.

Keep panels hidden when the active Space or the physical display binding is unconfirmed.

### Custom root discovery

Exercise the production AX reader and inventory admission for a successful empty AXWindows list with separately published focused/main elements, merged duplicates, foreign owners and whole-list failures. Cover seed, scan and launch retry for substantive AXUnknown roots. Require same-owner normal-layer native parent zero and confirmed nonmodal application parent. Keep child, modal, unknown-parent, utility, transparent and undersized rejection cases. New untitled roots need exact focus. An admitted root must still update confirmed minimized state after losing focus.

Keep two overlapping independent custom roots through repeated focus changes without token transfer or tab history. Delay an old inventory after its focus read, commit a newer focused-window result, then verify eligibility and active state before releasing a trailing inventory. Convert a root to a native child while AX succeeds or is unread. Remove its independent seat without a tombstone, retain it when native parent data is missing, and allow a detached root to return. Verify exact minimize, restore and close through the production executor without changing siblings.

These tests and an offscreen native WindowServer parent probe establish the generic mechanism. Use production diagnostics to establish a third-party application's AX behavior. Correlate its PID and window ID with the source SHA, discovery path and observed commands.
