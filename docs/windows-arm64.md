# Windows ARM64 build

This port builds a native Windows ARM64 desktop app with a bundled ARM64 JVM.
The portable ZIP contains `Nuvio/Nuvio.exe`; extract the entire ZIP before running
the executable. Java does not need to be installed. The build is unsigned and is
an unofficial derivative, not a release from Nuvio Media.

The app, graphics runtime (Skiko), JNA, WebView2 loader, JNI player bridge,
libmpv, QuickJS JNI runtime, and torrent engine all execute as ARM64. The ordinary
JNA and QuickJS dependency JARs may also contain unused resources for other
platforms. A native Windows ARM64 WebView2 Evergreen runtime is required for
the player controls, as in the original Windows application.

## Build locally

Use Windows ARM64, PowerShell 7 and Git. No Visual Studio installation is needed.
The script downloads checked, pinned tool archives into its work directory and
builds the two missing native libraries from their exact source revisions.
Allow several gigabytes of disk space and enough time for the initial dependency
downloads, native compilation, and Kotlin compilation.

Create `local.properties` with your desktop client/backend configuration, then:

```powershell
./scripts/windows/build-arm64.ps1
```

Or provide a configuration file and a separate cache directory:

```powershell
./scripts/windows/build-arm64.ps1 -LocalProperties C:/config/nuvio.properties -WorkDirectory C:/build/nuvio-arm64
```

Keep configuration out of source control. Relevant properties are
`NUVIO_SUPABASE_URL`, `NUVIO_SUPABASE_ANON_KEY`, `NUVIO_SUPABASE_FALLBACK_URL`,
`TMDB_API_KEY`, `TRAKT_CLIENT_ID`, `TRAKT_CLIENT_SECRET`, `TRAKT_REDIRECT_URI`,
`MDBLIST_CLIENT_ID`, and any optional integrations you use. Sentry upload
credentials and Apple signing credentials are unnecessary for a local build.

The ZIP is written into the work directory. The uncompressed app is in
`composeApp/build/compose/binaries/main-release/app/Nuvio`.
The portable build assembles the standard `jpackage` application layout using
the JDK's native ARM64 launcher template after Gradle stages its resolved
classpath and runtime. It does not require an installer tool such as WiX.

## Build a new official release in your fork

Open **Actions → Build Windows ARM64 → Run workflow** on your fork. Leave
`release_tag` as `latest`, or enter an exact NuvioMedia release tag such as
`0.1.30-alpha`. Download the `Nuvio-Windows-arm64-…` artifact when the run finishes,
extract the artifact and then the portable ZIP, and launch `Nuvio/Nuvio.exe`.

The action checks out that official release, applies `ports/windows-arm64/app.patch`
using Git's three-way merge, builds the missing native dependencies, runs the
port's tests, and verifies the packaged architecture. It uses the matching official
Windows MSI's published client constants after checking its official SHA256.
No initial secret is required. Optionally set the repository Actions secret
`NUVIO_DESKTOP_LOCAL_PROPERTIES_BASE64` to base64-encoded custom `local.properties`.
No signing or Sentry upload credentials are required.

The action uploads a portable ZIP, its SHA256 and `build-info.json` with the exact
upstream and port revisions. Manual runs do not publish a release or enable an
x64 auto-update. Published-release runs also attach these files to that release.
Actions artifacts are retained for 30 days; save the ZIP locally.

New releases work while the patch and native ABI remain compatible. If upstream
changes conflicting source, the engine ABI or QuickJS version, the action stops
with an explicit error. Update the patch/native pins before retrying; changing
architecture labels alone cannot supply missing native binaries. To refresh the
patch after editing the port, use `scripts/windows/update-port-patch.ps1`.

## Publish a Windows ARM64 GitHub release

The inherited **Update Sideload Source** workflow maintains upstream's iOS IPA
catalog. It runs only in `NuvioMedia/NuvioDesktop`; Windows releases in this fork
do not need an IPA. **Build Desktop Release** is also upstream's multi-platform
release process. Use **Build Windows ARM64** for this fork.

For a downloadable GitHub release, create a **new** tag such as
`0.1.30-alpha-arm64.1` targeting the current **Dev** branch, then publish its release.
The ARM64 workflow removes the `-arm64.1` suffix, builds official `0.1.30-alpha`,
and attaches its portable ZIP, checksum and `build-info.json` to your release.
Wait for the workflow to finish before downloading the assets.

Use a fresh tag pointing at the updated branch: an older tag can still execute
older workflows. Do not move an existing published tag. If you only want a ZIP,
run **Build Windows ARM64** manually with `latest` or an official tag and download
its Actions artifact. Manual builds do not create or publish a release.

Uploads never overwrite a different existing asset. For a rebuilt release, use
a new suffix such as `-arm64.2`. Publishing a release does not create an MSI;
this port currently distributes an unsigned portable ZIP.

## Scrolling and idle work

Windows scrolling defaults to 45% of Compose's viewport-scaled distance. Fractional
touchpad wheel events use their precise deltas without an additional wheel-smoothing
animation. Horizontal scroll and the OS full-page scroll preference are preserved.
To tune it, add `java-options=-Dnuvio.desktop.scrollScale=0.6` under `[JavaOptions]`
in `Nuvio/app/Nuvio.cfg`. Values from 0.1 through 2 are supported; restart the app.

When the window loses focus or is minimized, tab effects, hero auto-advance,
loaders, skeleton shimmer and decorative download/navigation animation pause.
Native playback and download services remain mounted. Hardware rendering remains
enabled. These changes reduce avoidable background work; battery-life improvement
depends on the content, integrations and GPU driver and has not been measured.

## Native dependency versions

| Component | Version or source revision |
| --- | --- |
| ARM64 Java | Eclipse Temurin 21.0.12.1+1 |
| Native compiler | LLVM-MinGW 20261006 UCRT, ARM64 host and target |
| WebView2 SDK | Microsoft.Web.WebView2 1.0.4078.44 |
| libmpv | shinchiro 20261016, mpv a2cd83c56d, aarch64 dev package |
| Nuvio Engine | Matches selected source: 0.1.4 at ddb383ba46bafb9970baf0bc23f51de786f58a4c, or 0.1.5 at 99a18601fa12858cc8c62576dc72b87edbd81b9a |
| libtorrent | 2.0.12, 740a0b9aeabe00e762cc0efe4a0f27593db2550b, with engine's upstream patches |
| OpenSSL | MSYS2 clangarm64 3.6.5-1, static libraries |
| QuickJS Kotlin JNI | 1.0.15, a081755bcdb18ee6afa7ffee25b8fa976f06d31f |
| QuickJS engine | 04be246001599f5995fa2f2d8c91a0f198d3f34c |
| c-vector | 774773d4cb1e66dd736e90e7f482d4f22af464c6 |

Source repositories and SHA256 checks for downloaded archives are recorded in
`scripts/windows/build-arm64.ps1`. Boost is fetched and verified by the engine's
upstream CMake dependency file. Native C++ runtimes are statically linked into
the LLVM-built bridge, so unrelated host MSVC redistributables are not copied.

## Implementation and verification

The Gradle build accepts `nuvio.windows.clang.path`, `nuvio.windows.engine.dll`,
and `nuvio.windows.quickjs.dll` in addition to the existing WebView2 and libmpv
directory properties. Native output directories include the architecture to
prevent stale x64 outputs from being reused. Packaging fails if any selected
native DLL has the wrong PE machine type or is missing.

The MinGW bridge supplies the COM callback helper missing from MinGW's WRL.
Its native test covers invocation, QueryInterface, reference ownership, and
exception handling. The engine loader accepts Windows ARM64 and never selects
the source tree's x64 engine DLL. The updater requires an ARM64 or aarch64
installer name on Windows ARM64, including when the release has only one asset.

To inspect a built portable app:

```powershell
./scripts/windows/verify-arm64-package.ps1 -AppDirectory ./composeApp/build/compose/binaries/main-release/app/Nuvio
```

The verifier checks PE headers of the launcher, all loose runtime EXEs and DLLs,
and the selected native libraries within application and dependency JARs.
This verifies architecture and packaging; it does not substitute for testing
playback, graphics drivers, authentication and integrations on your own device.

Windows ARM64 scraper calls use one background thread for native QuickJS calls.
This avoids races in QuickJS JNI 1.0.15's process-wide VM and class caches while
allowing suspended network requests to overlap. The build tests thread affinity
and 256 overlapping runtime lifetimes. Failed workflows save Gradle/native logs
and JUnit XML reports in the Windows-arm64-build-diagnostics artifact.

