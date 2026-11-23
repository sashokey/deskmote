# DeskMote

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
- Use Accessibility as the app’s privacy permission. The core needs it for windows and Command Shift uses it for the event tap. Preserve the input event and keep tests off the real window and input boundaries. Natural Switch follows external mouse presence while enabled and leaves the last direction in place on disable.
- Give each extension an independent target and embed phase entry. Use `DeskMoteWidgetBundle` to add widgets. Retain the air quality widget’s kind, intent type and input parameter names for installed instances. Give the widget the sandbox and HTTPS client entitlements. Finder Sync captures the folder and file type and submits them to its embedded XPC service. Authenticate both peers against their installed code signatures and let the service perform exclusive creation. Preserve numbered names and a valid ZIP with an empty folder.
- Keep app identifiers stable. Verify the graph alongside the package because an excluded extension or library can otherwise return as an implicit Xcode dependency.

## Maintenance

Use DeskMote’s history and release tag archives to identify the source corresponding to distributed binaries.

Use the following procedure for fixes.

1. Identify the affected subsystem and the last known working revision in DeskMote.
2. Add a regression test and make the smallest applicable change.
3. Preserve DeskMote's open-window model and module boundaries.
4. Check the diff for launchers, unrelated file operations, Dock changes and extra settings. Limit the Finder service to the two file creation commands and protect the existing taskbar behavior.
5. Run CI and the relevant Mac acceptance scenarios.
6. Record the affected behavior, reasoning and verification in the commit message.

Restoring a removed feature requires an explicit scope decision and review of its models, services, views, resources, project references and tests. Keep commits focused and explain the change, its reason, the preserved behavior and the verification. Follow SOLID, KISS and DRY. Review and test nontrivial changes before publishing directly to `master`.

Maintain the macOS 27 deployment floor across all targets. Use the pinned stable Xcode, with matching Swift 6 settings, for local and CI builds. Verify the Xcode version and build number. Update the runner and Xcode together when changing the supported toolchain. Keep Python and Node.js on stable releases. Record the effective macOS, Xcode, Swift, Python and Node versions in build logs for toolchain investigations. Pin official GitHub Actions to full release commit SHAs and check CI before accepting an update. If Dependabot is configured for Actions, use its daily schedule and the same CI gate. Use macOS system frameworks and keep the application, packaging and release flow free of third-party runtime packages.

### Artifact storage and recovery

The workflow retains the single `DeskMote` app artifact for seven days. Use GitHub Actions job logs for test and build failures. Preserve a failed release's verified ZIP until normal expiry so publication can resume.

Any authorized artifact cleanup must run its policy checks before obtaining Actions write access, use trusted `master` code and ignore fork or pull-request completion events. Apply the policy after CI or Release completes and when the policy changes. Keep the three newest completed artifacts per managed name and the newest successful result, including any legacy `test-results` and `xcodebuild-test-log` artifacts still present. Preserve active, triggering and unknown runs and unrelated artifacts. Limit deletion to Actions artifacts. Release assets, tags, source, runs and logs stay intact.

After `Re-run all jobs`, a resume must match successful validation and the versioned build with failed publication in the verified attempt. Use the single `DeskMote` artifact created during its successful upload step. Download by artifact ID and check its recorded digest. Stop on missing, expired or ambiguous artifacts, or a mismatched tag revision.

### Dev diagnostics and performance

Build a separate Debug base app with `PRODUCT_BUNDLE_IDENTIFIER=io.github.sashokey.deskmote.dev`. Keep both production and Dev self-identities out of inventory and helper ownership. Enable `DOCK_INVENTORY_LOG` and `DOCK_CLICK_TRACE` only for an agreed functional check. Keep their bounded journals in the Dev app's local log directory and use one running copy for desktop acceptance.

Compare CPU time and physical memory footprint on the same configuration, with matching diagnostics, displays and open windows. Use equal intervals for idle, window switching and Space switching. Mark phase boundaries and repeat before attributing small differences. Compare Release with Release to isolate the effect of a patch. A logged Debug run measures the combined cost of Debug and diagnostics.

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
  WindowCommandLifecycleTests WindowObservationLifecycleTests WindowRestorationTests
  WindowLiftContextLifecycleTests AppIconResolverTests PanelLifecycleTests
  TaskbarSpaceStoreTests TaskbarBehaviorTests WindowLiftBehaviorTests ApplicationBehaviorTests
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

Set `version`, `draft`, `prerelease` and `notes` in `.github/release.json` on `master`. Check the release run for the published commit. The workflow waits for both variants to pass, then attaches only `DeskMote-vN.zip` to the release. Verify that the tag points to the tested SHA and that the release and artifact have the expected ZIP. A failed publication leaves its verified package and draft available for recovery. Retry the failed jobs or use `resume_run_id` for the original release run when its retained artifact and tag match the request.

Run this from a checkout with the repository configured as `origin`, using the published tag.

```sh
tag=v1
release_checkout="../DeskMote-$tag"
git clone --branch "$tag" --single-branch "$(git remote get-url origin)" "$release_checkout"
cd "$release_checkout"
test "$(git rev-parse HEAD)" = "$(git rev-parse --verify "refs/tags/$tag^{commit}")" &&
test -z "$(git status --porcelain)" &&
test "$(python3 -c 'import json; print(json.load(open(".github/release.json"))["version"])')" = "$tag" &&
bash Scripts/build.sh full
```

Local and CI builds use the same Xcode, compiler options and ad hoc signature. The script signs the extensions before signing the app and verifies the final bundle. Compare the displayed revision with the published tag. Keep the local copy on the Mac.

## Taskbar reference and boundaries

Use public AppKit and SwiftUI components for UI construction and rendering. Keep private SkyLight calls confined to native window and Space integration.

The UI reference is Windows 11 Pro 26H2 (26300.9711), 1920×1080 at 100%, dark theme, Small taskbar, bottom, left aligned, with combining set to When taskbar is full and window buttons shown on the taskbar where the window is open. Use the live UI and Microsoft's current taskbar settings for this reference. The historical Win32 guide documents the Windows 7 taskbar. [Current Windows taskbar settings](https://support.microsoft.com/en-us/windows/experience/personalization/customize-the-taskbar-in-windows) · [Windows 7 design guide](https://learn.microsoft.com/en-us/windows/win32/uxguide/winenv-taskbar)

Retain only the open-window area. The observed taskbar height is 32, button height 28, top/bottom inset 2, icon size 16, and Start's outer left inset 10. Translate these to macOS points, not unscaled Retina pixels. Use the macOS system font and native app icons. The bar fills the screen width and touches its bottom edge.

Render the latest accepted window title on the next presenter update, including rapid tab changes and intermediate application titles during chat navigation. Do not freeze captions based on how often they change or wait for a quiet interval. Keep unread Accessibility titles distinct from known empty values. A failed read may preserve the last known title, while a successful read must reach the native button without an artificial hold.

A follow-up measurement kept five Terminal windows, two File Explorer windows, and fifteen Notepad windows separate in a 1,676-pixel button area. Compressed long buttons painted at 74–75 pixels with 2-pixel gaps. Adding another Notepad window combined Terminal. A short Clock caption painted at 66 pixels while space was available. A separate Windows Terminal window titled exactly `.` used a 39-pixel button and a 41-pixel pitch to the next icon. The label starts at 28 with an 8-pixel trailing inset. Keep natural caption width separate from the compression limit, and distribute fractional width across buttons without accumulating empty pixels. These are measurements of the configured reference, not Microsoft-documented universal constants.

Right-click actions use AppKit NSMenu and ordinary NSMenuItem rendering. Build the shared app menu from its common controls and available module sections. The base menu is Open at Login, Hide Status Bar Icon, a separator, and Quit. Internal reordering moves the existing button views within the taskbar. It must not create a detached system drag image. Use those same constrained group bounds to select an insertion position: the leading edge crosses a left neighbor's midpoint or the trailing edge crosses a right neighbor's midpoint. Do not require the pointer to enter another button. Compare with complete neighboring groups and their current layout slots, keeping the result stable during animation and repeated pointer events. Returning to the original slot must not persist a reorder. Hover and active transitions respect Reduce Motion. Keep the Windows-shaped neutral highlight and lower active underline/inactive dot. Do not replace them with an accent-filled macOS toggle or pill shape.

The live Windows reference was checked again with a manual pointer sequence, because the automation overlay does not move the real pointer and a synthetic drag is not a clean hover sample. Inactive hover and unhovered active have similar body fill. Active has a stronger edge and a longer colored indicator. Hovering active increases its fill and softens its edge. Holding a press darkens it. Preserve those distinctions with native neutral selection and separator colors over the Apple material, not an opaque accent fill or a hover that overrides active. A settled lossless capture measures the active underline at 11 by 2 pixels, one pixel above the button bottom. Translate this to points. The inactive indicator remains 4 by 2. Keep its horizontal center exactly aligned with the 16-point icon. An 11-point underline needs a half-point left coordinate at 1x. Rounding that edge shifts its center. Preserve the dimensions and vertical placement, and verify the rendered centers at 1x and 2x. An immediate transition frame is not evidence of its final width.

The taskbar and combined/overflow list use Apple's public [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview), with content inside `contentView`. Buttons compose public NSButton, NSTextField, NSImageView, and NSBox controls: AppKit draws the controls, while DeskMote supplies the measured Windows geometry and interaction state. The highlight uses `unemphasizedSelectedContentBackgroundColor`, with the original four-point corner radius and no filled accent color. Only the lower active indicator uses the system accent. Do not layer separate Liquid Glass surfaces on the buttons. Use the text field's alignment rectangle to retain the measured label insets rather than adding its intrinsic margins to them. Center that rectangle vertically on the icon and visible button, and use native backing-pixel alignment rather than rounding to whole points. At 2x the 15-point line is centered exactly. At 1x retain AppKit's nearest-pixel placement. Do not center on the enlarged bottom-edge hit target. The list uses NSTableView, native row selection, NSScrollView, and standard symbol close buttons over the glass. Keep all intervening backgrounds clear. The permission-recovery hint uses a SwiftUI GroupBox. Do not restore private glass selectors, a separate fake blur layer, or the former floating capsule/resize grip. Preserve existing window tracking, native tabs, display attribution, fullscreen visibility, and maximized-window avoidance.

The status icon uses public [NSStatusItem.isVisible](https://developer.apple.com/documentation/appkit/nsstatusitem/isvisible) with the stable autosave name `DeskMote.StatusBarIcon`, so AppKit preserves visibility across launches. Do not reset visibility on startup or ordinary activation. Handle [Finder reopen events](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:)) by showing the existing status item and returning false to suppress default window creation. Reopening an already running installed app restores the icon and its saved visible state without restarting the taskbar. Keep transient-install guidance unchanged.

No thumbnails or screen capture are allowed. A separate button has no hover popup. Combined groups and overflow use only window titles and application icons, including during file dragging. Closing the popup cancels pending row actions. ScreenCaptureKit and Screen Recording permission must not be reintroduced for these lists.

During a group drag, keep the committed order as the priority for combining buttons while moving their live layout slots to the proposed position. Recompute the priority after committing the move. A resize or inventory change can still remove the dragged button and cancel the move.

Accessibility remains necessary for window management. App Sandbox is incompatible with the retained cross-application Accessibility operations. See [Apple's restrictions](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox). Do not add privacy permissions to solve unrelated implementation issues. Derive core fullscreen visibility and taskbar routing from window and Space state. The optional Command Shift tap runs only for its own input-source shortcut. Treat window titles and diagnostic reports as potentially sensitive. They must not be uploaded automatically.

## Permission startup and recovery

On a normal installed launch without Accessibility permission, remain an accessory application and request only the native system prompt. Poll for the grant without opening a DeskMote guide or repeating the prompt. Elapsed time, an initial denial, or an ungranted permission is not proof of a broken permission record. A late grant starts the taskbar once in the same process. Quitting while waiting prevents a later grant from starting it.

Keep explanations for transient or read-only installations, sustained permission loss after startup, and failed recovery relaunches. Preserve the permission-loss debounce, panel suspension, window restoration, recovery guidance, and retry behavior. Do not reset privacy permissions or introduce new ones to test first-launch behavior. Use injected permission states for automated checks.

## Embedded helper windows

An embedded accessory process may own a visible window while a regular application provides its identity. Admit that helper only when exactly one running regular host contains its canonical bundle below Contents, both executables remain inside their own bundle's Contents/MacOS directory, and both processes have valid Apple-anchored signatures with the same Team ID. Verify code identifiers and process generations. Unknown, ambiguous, unsigned, mismatched, or escaped paths do not establish ownership. Do not add application-name exceptions or privacy permissions.

Keep the native window PID, bundle origin, generation, AX element and CG identity. Use the verified host only for presentation/grouping and ordinary Quit, validating both identities before Quit. Window activation, minimize, restore and close still target the native owner. Cache the binding after admission. Reuse existing focus/event refreshes and remove it on helper or host termination and tracker shutdown. Signing checks run during background admission, not rendering or focus polling.

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

Land each completed periodic AX read and release its PID before reading the next application. A slow application must not hold another application's ready result or trailing event. Coalesce pending snapshot publication on the main queue without adding a timer. A newer immediate rebuild supersedes the queued publication. Reuse one immutable application-candidate list per ownership pass, but revalidate each helper and host generation and signature before accepting its binding.

Skip the full CG list on launch retries with an empty or unread AX result. When a Space notification requires an immediate fullscreen check, share one on-screen CG capture across the participating panels. Each panel classifies its own display and the delayed fallback reads fresh data.

Use one background probe of visible CG window IDs on the 500 ms foreground tick. Read full AX inventory on changes, real events, due absence work, or the five-second fallback. Keep the lightweight system-focus check for tracked helpers. Take any probe used to confirm a full CG snapshot after the AX read and before the full capture. Advance the foreground baseline only on a successful inventory with confirmed CG evidence.

Keep one inventory backoff per process generation. After successive unread rounds, wait at least 0.5, 1, and 2 seconds before retrying. After these retries, use only periodic reconciliation until success or process replacement. Keep the latest coalesced event through the wait and use the existing ticks to resume it. An unread round preserves the last confirmed inventory.

Read minimized state, title, position, size, role, and subrole in one AX attribute batch per window. Preserve individual AX errors. Use scalar reads for unsupported batches or ambiguous fields within the original budget. Apply the inventory backoff after a batch timeout.

Queued AX subscription removal belongs to its observation session. Stopping that session cancels pending cleanup, releases its queued elements, and prevents the next native removal from starting. An already admitted call may drain. Retiring an element from a live session still removes all required notifications. Release phantom-held diagnostic episodes when their seats retire. Admission history used only by tests is Debug-only. Runtime diagnostics use the bounded inventory log rather than unconditional console dumps.

Use a successful on-screen CG capture as liveness evidence when it contains every saved session and suppression identity. Missing identities or an unavailable capture still require the full window list. An unavailable full list is unknown.

Use one five-second fullscreen timer across panels. Share a fresh focused-window observation within each check and classify it for each display. Read managed Spaces in the background worker and carry the result with its display, geometry, probe and hold generations. Use the carried result for Space evidence in the UI callback.

Keep the per-window Space membership read authoritative in Release and in Debug verification mode. Use `DOCK_SPACE_BATCH_MODE=verify` to compare per-Space results on real desktops before enabling the batched path. Check moved, minimized, hidden, fullscreen, and shared-Space windows. Retain scalar lookup for parked windows and missing results. Discard the capture when its layout changes or its read budget expires.

During a group drag, reuse text measurements and move only the dragged frames while the insertion slot is unchanged. A combined/overflow list stores window models and asks NSTableView for reusable rows near its viewport. Cancel a removed row's delayed file hover before reuse, and rebind its title, selection and exact-window actions.

On application activation, cancel only initial height-adjustment writers that have not consumed their active-owner validation gate. Once the first size write is authorized, finish the bounded, geometry-verified adjustment even if focus changes. Focus loss must not roll an already applied size back to the original full height or discard restoration metadata. Stop, permission recovery, retired display contexts and external geometry retain their separate cancellation/restoration rules.

Maintain an already confirmed height adjustment if the same window returns to its known native frame while its application is inactive. Keep the active-application requirement in the pending validation for initial adjustments. Only maintenance of a confirmed managed frame may continue in the background, including across an activation notification during validation. Recheck process generation, display context, the native CG/AX frame and window capabilities before writing. Preserve manual geometry and leave previously unmanaged inactive windows untouched. Use the existing observation and fallback paths without another timer or input observation.

Bottom-docked tiles may extend horizontally beyond their owning display. Keep the majority-overlap requirement, minimum dimensions, bottom alignment, top bound and second aligned edge. Horizontal containment is not required. Reuse the maximized detector's menu-reserved visible frame when a secondary display reports its entire screen as visible. A full-height window moved partly beyond either side must still clear the taskbar, preserving its top, left and width. Keep the tiles kill switch, application-independent detection, native AX validation and restoration of the latest accepted frame.

An animated write whose guarded rollback fails must retain its original geometry in the existing pending-restoration queue. Also retain a potentially mutating write failure whose rollback was not requested because its first changed frame could not be acknowledged. Keep its abandoned session and standoff count until restoration or normal lifecycle cleanup. Do not strand a managed intermediate frame or grant a new retry budget. A window with pending restoration cannot start another lift, including between delayed restoration attempts. Restoration uses the existing cancellation, process-generation and external-frame guards, retry cadence and operation limits. Successful restoration lets ordinary detection retry an active window. A manual frame or replaced process is never overwritten.

Changing or removing one display context restores only windows owned by that context. Reordering contexts or adding an unaffected display must preserve the other sessions and their original geometry. Cancelled writers must finish before their window is restored, including when another restoration is already running. Release completed writer references without dropping outstanding work during Accessibility recovery.

Stopping is idempotent even after monitoring and visible sessions have already been cleared. Retired writers still belong to the controller: transfer their drains to the existing restoration completion path and await them before stop-and-restore returns. Do not infer that shutdown is complete from an empty session list or a disabled polling timer.

The focused-window observer uses the shared AX observation session, with messaging timeouts on each individual AX element. Create and register off the main actor. Attach and detach the run-loop source on it. Coalesce refreshes and retargeting, cancel obsolete operations, and reject callbacks from older lifecycles. A transient focused-window read preserves the last confirmed registration. Failed reads and registrations retry through the existing fallback tick, not through a new timer or an immediate retry loop.

Fast window-lift probing is limited to an active write and the existing one-second application-response interval after settling or abandonment. Probe only those transitioning windows. A retained stable session needs restoration metadata, not a permanent 20 Hz probe. Settled windows use geometry events and the one-second global fallback. A fallback read must still discover external geometry changes when AX notifications are unavailable. Preserve all native geometry validation and standoff limits.

An unresolved application icon can be cached between renders, but application launch/activation invalidates that unresolved result. Notify the presenter so the existing button refreshes even if the window inventory did not change. Keep successful icons cached and perform file-stamp checks off the main actor.

## Inventory and action identity

A matching frame or size does not establish that two minimized windows are native tabs. Keep independent windows at startup. Retain positively observed tab membership and shadow evidence. A visible tear-out needs an unambiguous old seat and a replacement without its own independent seat. Minimized members are not visible tear-outs. Keep every physical seat token stable and every CG ID unique in the ordered inventory.

Treat a failed CoreGraphics capture as unknown for destructive decisions. Preserve AX-absent seats, histories, shadow evidence and cached handles until a successful CG capture confirms absence. Positive AX updates may still land in that round, including an unambiguous visible switch to a previously observed tab member without its own independent seat. Geometry alone cannot establish a replacement while CG is unknown. A successful empty capture remains different from a failed one.

Application observer readiness includes its application-level subscriptions, not only an allocated AX session. Retry temporary creation and registration failures from the existing periodic fallback using the subscription backoff. Keep established window subscriptions and reject results from a stopped generation. Unsupported notifications remain terminal and retain periodic coverage without repeated registration.

An open combined/overflow list must invalidate its rows and delayed actions when their process, CG or action identity changes, even when the stable seat ID is unchanged. A separate button's delayed file hover must capture and validate the original identity, then allow a fresh hover after rejecting a stale target. A title-only update may update the existing rows. Preserve external window titles literally, including a window whose title is exactly `DeskMote`.

Keep the command identity tied to the accepted AX element when a process reuses a CG ID. A replacement element invalidates queued commands while retaining the visual seat. Compare any acquired AX target to the captured element before sending the window command.

Taskbar buttons and window lists use pointer actions. Right-click opens the native context menu. A clicked list stays open until dismissal or another deliberate action. Pointer exit uses the existing grace period for hover and file-drag lists. Clicking cancels pending hover from other groups, and later hover cannot replace a clicked list.

Destructive tab inference and phantom cleanup require current native-root, raw-AX absence, subscription identity and AX/Space evidence. A failed read is unknown. Keep live minimized windows and windows assigned to another Space. A minimized-at-startup window can be independent even when it has never been seen visible. Preserve positively learned tab membership. Phantom cleanup also requires a matching current sibling frame so an unrelated window does not become a shadow tab.

Close can supersede a pending activation or minimization of the same window. Repeated Close remains coalesced while its accepted operation is pending. Confirm helper activation against the exact system-focused native window when its verified host remains frontmost, revalidating the host generation and bundle origin.

At dequeue, check a panel action against the Space revision and visible window representative from its original panel. Discard commands that lost their projection before native execution and clear their pending feedback.

A Space notification also cancels in-flight panel actions before their next native effect and allows calls already started to drain. When a new Space is confirmed with a partial window read, hide windows with unconfirmed membership. Keep previously confirmed membership for the same parked window and require fresh membership when a replacement AX target inherits its CG ID.

Save canonical application keys alongside the same-boot window order. Reconstruct application ranks from those keys when a new tracker assigns different seat serials. Retain the existing missing-window grace and new-boot reset. Session-local serials are not persistent application identities.

Synchronous window-lift validation, writes and guarded cleanup run through the blocking-work bridge on a serial geometry queue. Validation and animation share a one-second admission budget. An already started native call drains before cancellation cleanup. Distinguish a write refused before admission from an admitted AX error, which may have changed the window. Cleanup has an independent bounded budget and may restore only the acknowledged or just-attempted managed frame, never a manual replacement. Release obsolete observation watermarks after all relevant scans and writer drains can no longer apply them.

For guarded AX writes, batch the frame attributes on both sides of native identity validation when the application supports the batch. Recheck any corroborated identity attribute in the final batch. macOS exposes frame reads and writes as separate AX calls, so an external change can still occur between them. After a cancelled write returns an uncertain result, keep the existing bounded observation window even if the first rollback succeeded.

## Verification and regression policy

Tests describe the agreed behavior and independently observed reference scenarios. A failing assertion is a reason to investigate the implementation, not to weaken the expectation. Change an expectation only when the requirement or verified reference behavior changes, and explain why in the commit.

Use RED → GREEN → REFACTOR for behavior changes: first run a regression test and confirm that it fails for the reported defect, then implement the smallest correction and run the complete suite. A compilation error is not evidence that the test detects the defect. Refactor only while the behavior tests remain green.

Keep fixture setup and test-only helper methods in test sources. Replace external AX, WindowServer, and application lookup operations at their boundaries. Exercise the production controllers and assert their resulting state, requested operations, or rendered content. Derive expected values independently of the implementation.

### Automated checks

Run the verification commands above. CI runs the full and base test suites, checks deployment availability, builds arm64 Release products and verifies the ZIP, signatures, identity, rights, deployment target and checksum. Preserve failed test and build logs. Use the extended commands for coverage and constrained-executor regression checks.

Use the pinned Xcode for local builds and tests. Repeat native checks on the available supported macOS. Keep DerivedData and XCTest runtime data in a location Xcode can access. A background test runner may be denied access to a test bundle inside a protected Documents folder even when compilation succeeds. Do not change system privacy settings to work around this silently.

Keep test coverage for the following behaviors.

- Window identity, inventory admission, minimized/hidden retention, native tabs, activation, focus handoff, and permission recovery.
- Ordered window-command execution, cancellation between external operations, rapid minimize/activate replacement, independent close requests, and draining in-flight commands across runtime stop/restart. Tests assert external effects as well as published state.
- Background AX observer creation and registration, windows discovered during registration, stop or window retirement/replacement during a blocked call, subscription cleanup, and rejection of late callbacks from a replaced session.
- Failed or unverifiable frame restoration stays pending. Bounded retries complete confirmed writes and preserve unresolved state. Permission uncertainty cancels and drains restoration without dropping saved geometry. Cancellation after a read prevents the next write. Changed process identities and user-moved windows are never overwritten.
- Unknown fullscreen observations preserve the previous state. Periodic checks also run while the bar is visible. Geometry events trigger coalesced checks without input observation.
- Current-Space filtering per display, fullscreen-window removal from its former Desktop, shared Spaces, retained minimized-window membership, failed Space reads, coalesced background reads, stop/restart, and preserved manual order. Combined close actions only contain windows on the visible Space. Display-only inventory changes refresh Space membership without waiting for the periodic fallback. Two offscreen presenters exercise transfer in both directions with polling disabled. Rapid transfers coalesce, stale reads cannot overwrite current membership, and same-display geometry/title/focus changes do not trigger extra Space reads.
- Native transient panels hide in Mission Control. A windowed AX result from system UI cannot reveal a panel while its display remains in a fullscreen Space.
- No-screen startup, display disconnect/reconnect, and separate handling of missing display UUIDs. Native panel creation is replaced in lifecycle tests so no window is shown.
- Bounded process-generation caching and cleanup after process termination.
- System-only initial permission prompting, continued waiting without a guide or repeated prompt, late grants, grants arriving during startup, and quitting before a grant. Confirmed runtime recovery and transient-install guides remain covered separately.
- Display attribution, topology changes, state-based fullscreen visibility, and maximized-window clearance. The measured Chrome fullscreen-return case keeps its menu-bar inset even when NSScreen reports a larger visible frame. Recognition accepts both system layouts without moving the window top or relaxing the other edge checks. Side/bottom Dock reservations and camera safe areas remain covered. Suppression recovery replays the measured return-to-Desktop frame, its first lift, and a subsequent maximize with a different top inset. Changed eligible geometry retains the retry budget, including delayed changes and repeated alternation. Floating frames and permission-freeze suppression remain protected. Restoration uses the newly accepted geometry.
- Separate labeled buttons, content-sized short captions including the exact `.` reference, the measured 74-point compressed width for long captions, pixel rounding, combining under crowding, expansion after space returns, and accessible overflow.
- Whole-application group moves selected by the dragged leading/trailing edge crossing the neighboring group midpoint, unequal widths and different grab positions, stable repeated pointer events, round trips without persistence, preserved member order, mouse-up outside, and windows/apps or available width changing during a drag.
- No hover popup for separate buttons. Icon/title lists for combined groups and overflow only.
- Popup dismissal on its own window losing focus, own-view pointer/drag presence, and stale focus notifications from replaced panels.
- Native AppKit context-menu items and action dispatch, exact-window activation and close actions, Close all windows for a combined group, and Quit as a separate application action.
- File-drag hover activation, cancelled delays, stale targets, and list disposal.
- Detached AppKit rendering and input routing through an injected popup presenter. These tests must never display windows over the user's desktop or request screen capture. Native mouse-tracking checks may attach views to a panel that is never ordered on screen. Detached image rendering checks control geometry and content. It does not establish WindowServer glass refraction or transparency against the real desktop.
- Native controls with preserved icon/text alignment, neutral hover/active feedback, lower indicators, animated-state settling, Reduce Motion, transparent native list backgrounds, native table mouse tracking, pointer scrolling and exact-row close dispatch. Explicit line separators in captions render as spaces on the original single baseline, with width measured from that same visible text. Raster comparisons cover LF, CRLF, CR and Unicode line/paragraph separators at 1x and 2x in both appearances. The original title and Accessibility label stay intact. Independently compare caption pixels with a native Auto Layout centerY reference at real 1x/2x backing scales, including truncation, fallback glyphs and color emoji. Assert the shared visible panel center separately, including the 30-point hit target. The native 1x grid rounding must not become a whole-point rounding on Retina.
- The manually observed Windows state hierarchy, applied to both AppKit appearances: similar hover/active body fill, stronger active edge, stronger fill on active hover, and darker held presses. The active underline is 11 by 2 points with a one-point bottom gap. Its horizontal center must equal the icon center exactly, including at 1x where its left edge falls between pixels. Check both the view/backing geometry and the centers of the actually rendered icon and indicator at 1x and 2x. A half-pixel centering tolerance hides the defect.
- Bottom-edge hit testing and hover tracking at 1x and 2x, exact-window clicks, combined/overflow lists, file-hover activation, preserved horizontal gaps, and cancelled clicks outside the bar. Raster comparisons verify that larger hit targets do not change the 28-point visible buttons.
- Ordered common menu commands, sections driven by the installed modules, checked visibility toggling in both directions, native-restored visibility, icon restoration and independent login/quit actions.
- Launch-at-login state, localization, debug-switch registration, pinned toolchain selection, release publication, and verification of the artifact retention policy when changing it.

Coverage reports identify untested paths. A count or percentage alone does not establish correct behavior. Automated tests cannot establish real Accessibility interoperability, native WindowServer animation, or hot-plug behavior on every Mac.

### Main behavior integration

`TaskbarBehaviorTests` drives the production presenter, runtime, planner, command queue, action executor and AX reader against a stateful boundary for Accessibility, WindowServer and application operations. It checks minimize-to-restore without a CG entry, exact group/list and file-hover activation, close and combined close, ordinary Quit, rejected identities, failed confirmations, cancellation during handle capture, and persisted or cancelled group moves. Assertions include observed window state and resulting taskbar content. The executor itself is not replaced.

Title-update regressions replay repeated browser tab open/close titles and chat/application-name transitions through the production runtime and presenter into native button captions and Accessibility labels. Drain queued updates without waiting for a quiet interval. Assert each accepted title replaces its predecessor while the button identity and window order remain stable. Reader and inventory tests separately cover unread titles, known empty values and window replacement.

`WindowLiftBehaviorTests` exercises the production CG candidate parser, lift controller, handle validation, AX frame writer, verification and restoration. Keep the Chrome fullscreen-return and repeated-maximize paths, manual geometry preservation and rejected unconfirmed writes. Hold a pre-write CG scan until after the height writer confirms completion. Its late result must not restart the adjusted session. Keep this ordering test nonblocking for the Swift executor, and control automatic fixture polling rather than relying on a race between timers.

After a confirmed adjustment, deactivate the application and return its window to the known native frame both inside and outside the application-response interval. Assert renewed bottom clearance without reactivation, with the same top, left, width and unrelated window geometry. Deliver an activation notification while maintenance validation is blocked. Keep regressions for manual geometry changes during that validation, rejected process-generation reuse and untouched unmanaged inactive windows. Ordinary initial-write focus cancellation must still pass.

Move a full-height window partially beyond the left and right display edges, keeping most of it on that display. Exercise both half-width and wider-than-screen frames, negative display origins and the production CG candidate gate. The production controller must apply bottom clearance through size-only AX writes, with animation enabled and disabled, across repeated moves. Other windows stay unchanged. Stop restores the latest accepted native frame, while a subsequent manual move or resize remains untouched. Keep small, floating, vertically misaligned and mostly offscreen windows excluded, and retain the tiles kill switch. Native acceptance should repeat this sequence with ChatGPT and Discord. Injected tests do not establish either application's native AX behavior.

Replay the measured ChatGPT frame `(3797,30,1339,1410)` in Quartz coordinates on a secondary display `(2560,0,2560,1440)`, with both full-screen and menu-reduced visible frames. Expect `(3797,30,1339,1376)` and restore the original frame on stop. For the Discord failure path, make AX frame reads fail after an admitted animated size write so immediate rollback fails. Then restore reads. The existing restoration queue must restore the original frame and permit ordinary active-window detection to complete clearance, while manual geometry and reused process identities stay untouched. Keep automated frames and native acceptance results distinct.

Cover failed reads both before and after the first changed frame is acknowledged. Let restoration exhaust its immediate attempts, then have the application return to its native frame before the five-second delayed retry: no new writer may begin while that recovery is pending. Once handled, the next verified lift keeps its standoff count, and no stale recovery may restore over the completed adjustment.

Geometry-only fixtures inject a private workspace notification center so real desktop activation events cannot cancel synthetic processes. Verify that a native activation cancels the ordinary pre-write path, while the private-center fixture completes the same geometry operation. Keep focus-transition lifecycle tests on the real notification center.

`ApplicationBehaviorTests` enters through AppDelegate for first launch, late grants, reopen, permission suspension, recovery and termination. Replace native presentation and application/process operations so these checks never open windows, modify TCC, terminate other processes or change the user's desktop. Runtime, panel orchestration, permission coordination and restoration stay real.

When changing these paths, prove the corresponding regression test rejects a missing action or write: disconnected toggle/activate/close/reorder, omitted normal termination, unconditional command failure, skipped unminimize, skipped lift write, and skipped reopen icon restoration. A compilation failure does not count as detecting the regression. Run the complete suite after restoring the implementation.

Coverage summaries select the `DeskMote.app` target. Test sources and duplicated source copies belong outside the application metric. Tests must assert the end effect of each core flow. No aggregate line percentage establishes that contract.

### Mac acceptance

Use the app from the exact tested commit. Keep ordinary automated checks in the background. Obtain explicit agreement for a foreground launch or real desktop interaction before starting native acceptance.

#### Window-manager checks

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
| Chrome window created from fullscreen | Create a new Chrome window while another Chrome window is fullscreen, leave the new window's fullscreen Space, then maximize it on the Desktop with DeskMote. Check both a quick maximize immediately after its first height adjustment and another after a pause. Repeat maximize/restore: an earlier adjustment must not permanently suppress the new geometry. Its bottom clears the taskbar while its menu-bar inset, top, left and width remain unchanged. The fullscreen sibling is untouched. |
| Maximize, restore, manual move/resize | Maximized windows avoid the 32-point bar. Manual geometry remains respected. Repeated maximization at user pace reapplies the reserved height. Titlebar double-clicks are handled by the target app. DeskMote no longer infers a request to restore a smaller frame from global click counts. |
| Two displays, Spaces and moving windows | Each bar shows windows on the current Space of that display, including minimized windows assigned there. Windows on other Spaces, including fullscreen Spaces, are omitted. Move a window between displays in both directions: its button appears on the destination without waiting for the periodic Space refresh, and unrelated buttons retain their manual order. Switching back restores the buttons in their manual order. Grouping and close actions use only the visible windows. |
| Mission Control from Desktop or fullscreen | The taskbar is hidden on both monitors by native AppKit transient-window behavior. On leaving Mission Control, it returns on regular Desktops and stays hidden on fullscreen Spaces. No input observation is used. |
| Disconnect/reconnect, sleep/wake | No stale panels, duplicate buttons, or inaccessible windows after attribution settles. |
| Fullscreen and Spaces transitions | The bar follows actual window/Space state and returns after the transition. Pending popups/actions are cancelled. A brief appearance during the transition animation is possible because input-based prehiding has been removed. |
| Accessibility revoked/restored | Panels and pending actions suspend safely. Core operation resumes after permission recovery. Check the optional shortcut module independently. Inject trust changes in automated checks. |
| Native Dock | Its preferences and process remain untouched. |

Use macOS 27 or later for physical Mac acceptance and the pinned hosted runner for automated tests. Describe OS, scale, display arrangement, version, source revision, steps and observations for failures. In repository documentation, use de-identified information for examples and results. Exclude local account names, personal paths, dates and timestamps. Describe the user's computer only as a MacBook with Apple silicon.

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

Mutation checks must detect removed signer equality, path containment, host generation validation, dialog boundaries and native AX ownership filtering. Keep mutation copies separate from the source used for release. Automated fixtures do not establish that a third-party app exposes the expected native AX roles or accepts its window commands. Record Steam and Terminal Profiles acceptance separately when a native test session is available.

### Review regression coverage

Use the production lifecycle controllers with injected AX sessions, a monotonic clock, window probes, and restoration operations. Keep the test views offscreen and do not revoke live Accessibility permission.

- For the geometry observer, cover blocked startup, registration and reads, rapid app and focus changes, stop, stale callbacks, transient errors, fallback recovery and bounded retries.
- For focus during window height adjustment, deliver a real local workspace activation notification while an AXSize write is held after mutation. The old window must finish at the adjusted height and retain restoration metadata, with animation both enabled and disabled. Normal stop must still restore the original size. A switch before the first write must leave that window untouched.
- For context isolation, remove a display, change its geometry, reorder displays, retain unaffected sessions, and await a second cancelled writer while a first restoration is in flight.
- For a long-settled session, assert zero fast per-window queries. Then fast probes include only transitioning windows and expire after the response interval. Verify event-driven refresh and fallback discovery of external geometry changes with a fake clock and counted probe calls.
- For inventory, closing the last window leaves no synthetic card and retains the application observer. Process churn releases mutation generations. A late response from an old process cannot consume a replacement process's in-flight read.
- For icons, unresolved lookup retries on launch and activation, repeated renders use the cache, resolver lifetime is independent of notifications, and icon recovery refreshes an existing button without an inventory update.

The constrained Swift-executor pass includes the geometry, context and icon regressions. Retain behavior tests for window order, native tabs, actions, rendering, display attribution, permissions, restoration, and the Chrome fullscreen-return geometry. Remove assertions only for intentionally removed app-only card contracts and unused model fields.

### Review regression boundaries

Hold a second application's periodic AX read and verify that the first application's ready title is published and its next event completes before releasing the second reader. Keep unread, stale-token, generation-replacement and stop coverage. Count running-application enumeration across an ownership batch with multiple helpers and a missing PID. Expect one candidate snapshot while host-generation changes and signature failures still reject bindings. A cancelled batch must not enumerate or check signatures.

Block one subscription removal, queue more, stop the observer and restart with a fresh session. After the admitted call drains, no further removal may target the old session. Live retirement still unsubscribes normally. Repeatedly retire phantom-held seats while their process survives and assert that diagnostic state returns to its live cardinality. Independent minimized startup windows must retain their seats without unconditional debug output.

Count CG calls for visible saved identities, missing/offscreen identities, reused window numbers under a different PID and failed captures. Include suppression identities without admitting them as lift candidates. Fullscreen-worker tests must prove off-main Space reads, fresh true/false transitions and rejection of results from older probe, display geometry and hold generations.

Move a taskbar group repeatedly within one insertion slot and assert that unchanged icon/content work is not repeated. Scroll a long native list through a small viewport, verify bounded row reuse and exact activation/close targets, and cancel file-hover activation when its row leaves the viewport. Keep pointer activation, title-only refresh, rendered geometry and disposal tests on native cells obtained from the table rather than eager row storage.

Keep production-reconcile tests for overlapping independent windows, an independent window entering a vacated frame, same-size minimized startup windows, a positively observed native tab switched and minimized after moving, visible tear-out, and failed versus successful-empty CG captures. Failed captures must preserve cached handles and old histories while accepting positive AX changes, including a new window at a retained window's old frame and a known tab switch that preserves its original seat through CG recovery.

Observer tests must exercise nil factory recovery, transient application-level registration, already-registered and unsupported responses, preservation of established window subscriptions, and stop during blocked recovery. Unsupported is not an immediate-retry loop and does not establish complete event coverage.

Keep a retired writer blocked after monitoring and its visible session are cleared. Stop-and-restore must remain pending until that writer drains, then release its references and observation metadata without another window write. This ordering must be controlled by a continuation rather than a timer or a longer assertion timeout.

For list identity, open both combined and overflow lists, change the CG/action target or process generation without changing the seat ID, and assert dismissal plus cancellation of stale file-hover and row actions. Reopening must target the replacement. Keep a title-only update open and actionable. Reject a separate button's stale pending file hover and allow a fresh hover on its replacement. For order persistence, create two real tracker lifecycles with different seat allocation histories. Also cover empty/partial startup snapshots, identity learning without a reorder, direct return after the absence grace without an intermediate sync, and a new boot. Verify an external window titled DeskMote retains its title through the real presentation path.

Run native-lift progress checks with the constrained Swift executor. Hold an AX read or size reply while an independent async task must progress. Cancel a queued operation before it starts native work. After an acknowledged animation step, cancel a queued later step through begin/end permission uncertainty and verify restoration before the frozen state converges. Confirm the synchronization gates did not time out. Exercise a shared operation deadline, refusal before a later write's admission, expiry after mutation, and an admitted native timeout without mutation after a successful animation step. Each cleanup must preserve a manual replacement frame. Churn windows while the controller remains enabled and verify obsolete metadata is released only after outstanding observations and drains are safe. Test cache retention on the production cache, without a separate test-only copy of its set operation.

Review fixes additionally cover independent off-Space windows with the same frame under both existing-sibling and new-sibling admission order. Unknown and stale AX/Space/session evidence. Minimized-at-startup omissions and return without false tab learning. And positive dormant native-tab controls. Drive the existing bounded background probe path, including process replacement during a read.

Hold activation and minimization before their external effect, send Close for that same window, and verify only the replacement close executes after the admitted call drains. A duplicate Close must retain the original accepted operation. Confirm helper activation and restoration through the production executor's return value as well as native state. Periodic feedback reconciliation must not mask a false result.

Clicked combined and overflow lists survive pointer exit without focus loss. Hover and file-drag lists retain their exit grace. Clicking a group cancels a previous group's delayed hover, and further hover cannot replace the clicked list. Preserve native focus-loss dismissal and exact row actions.

Exercise controller-only trust loss that the watchdog does not observe, repeated trusted samples during a blocked writer, refreeze and termination during unfreeze, and frozen-at-entry shutdown after trust returns. Keep restoration denied while trust is false and wait for every admitted writer before returning. Reject old fullscreen geometry with both identified and unidentified displays.

### Custom root discovery

Exercise the production AX reader and inventory admission for a successful empty AXWindows list with separately published focused/main elements, merged duplicates, foreign owners and whole-list failures. Cover seed, scan and launch retry for substantive AXUnknown roots. Require same-owner normal-layer native parent zero and confirmed nonmodal application parent. Keep child, modal, unknown-parent, utility, transparent and undersized rejection cases. New untitled roots need exact focus. An admitted root must still update confirmed minimized state after losing focus.

Keep two overlapping independent custom roots through repeated focus changes without token transfer or tab history. Delay an old inventory after its focus read, commit a newer focused-window result, then verify eligibility and active state before releasing a trailing inventory. Convert a root to a native child while AX succeeds or is unread. Remove its independent seat without a tombstone, retain it when native parent data is missing, and allow a detached root to return. Verify exact minimize, restore and close through the production executor without changing siblings.

These tests and an offscreen native WindowServer parent probe establish the generic mechanism. They do not establish a third-party application's unrecorded AX attributes or native post-fix acceptance. Record the real application's PID/window ID, source SHA, discovery path and observed commands before treating its original issue as verified.
