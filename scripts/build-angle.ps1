#Requires -Version 7.3
param(
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$Revision
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = Split-Path $PSScriptRoot
$work = Join-Path $root '.angle-work'
$angle = Join-Path $work 'angle'
$depot = Join-Path $work 'depot_tools'
$dist = Join-Path $root 'dist'
$url = 'https://chromium.googlesource.com/angle/angle.git'

if (-not $Revision) {
    $Revision = (git ls-remote --exit-code $url refs/heads/main) -split '\s+' |
        Select-Object -First 1
    if ($Revision -cnotmatch '^[0-9a-f]{40}$') { throw "Invalid ANGLE SHA: $Revision" }
}

# Apply to every checkout made by gclient, including its nested build repo.
$env:GIT_CONFIG_COUNT = '2'
$env:GIT_CONFIG_KEY_0 = 'core.autocrlf'
$env:GIT_CONFIG_VALUE_0 = 'false'
$env:GIT_CONFIG_KEY_1 = 'core.longpaths'
$env:GIT_CONFIG_VALUE_1 = 'true'
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
$env:GYP_MSVS_VERSION = '2022'

$kits = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots').KitsRoot10
$sdk = Get-ChildItem -LiteralPath (Join-Path $kits Include) -Directory |
    Where-Object {
        $_.Name -match '^10\.0\.\d+\.\d+$' -and
        (Test-Path (Join-Path $_.FullName 'um/d3d11.h')) -and
        (Test-Path (Join-Path $kits "Lib/$($_.Name)/um/x64/d3d11.lib")) -and
        (Test-Path (Join-Path $kits "Lib/$($_.Name)/ucrt/x64/ucrt.lib")) -and
        (Test-Path (Join-Path $kits "bin/$($_.Name)/x64/rc.exe"))
    } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $sdk) { throw 'No complete Windows SDK with x64 libraries was found.' }
$env:ANGLE_WINDOWS_SDK_VERSION = $sdk.Name
$env:WINDOWSSDKDIR = $kits

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Install Visual Studio 2022 with the C++ x64 toolset.' }
$env:GYP_MSVS_OVERRIDE_PATH = $vs
Write-Host "ANGLE $Revision with Windows SDK $($sdk.Name)"

New-Item -ItemType Directory -Force $work, $angle, $dist | Out-Null
if (-not (Test-Path (Join-Path $depot '.git'))) {
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git $depot
}
$env:PATH = "$depot;$env:PATH"
@"
solutions = [{
    "name": "angle",
    "url": "$url",
    "managed": True,
    "custom_deps": {"angle/third_party/SwiftShader": None},
    "custom_vars": {"checkout_angle_dawn_deps": False},
}]
"@ | Set-Content -LiteralPath (Join-Path $work '.gclient') -Encoding ascii

Push-Location $work
try {
    gclient.bat sync --no-history --revision "angle@$Revision" --reset --force
} finally {
    Pop-Location
}
if ((git -C $angle rev-parse HEAD) -cne $Revision) {
    throw 'gclient checked out a different ANGLE revision.'
}
$buildRepo = Join-Path $angle 'build'
$buildRevision = git -C $buildRepo rev-parse HEAD

$anglePatch = Join-Path $root 'patches/angle-complete-gles.patch'
$buildPatches = @(
    (Join-Path $root 'patches/build-portable-archives.patch')
    (Join-Path $root 'patches/build-local-sdk.patch')
)
git -C $angle apply --check $anglePatch
git -C $buildRepo apply --check @buildPatches
git -C $angle apply $anglePatch
git -C $buildRepo apply @buildPatches

Push-Location $angle
try {
    New-Item -ItemType Directory -Force out/Release | Out-Null
    $sdkPath = ($kits -replace '\\', '/').TrimEnd('/')
    $vsPath = $vs -replace '\\', '/'
    $gnArgs = @"
is_debug = false
is_component_build = false
symbol_level = 0
use_thin_lto = false
use_custom_libcxx = false
target_cpu = "x64"
angle_enable_vulkan = false
angle_enable_wgpu = false
angle_build_vulkan_system_info = false
angle_build_all = false
angle_build_tests = false
visual_studio_path = "$vsPath"
visual_studio_version = "2022"
windows_sdk_path = "$sdkPath"
windows_sdk_version = "$($sdk.Name)"
wdk_path = "$sdkPath"
"@
    $gnArgs | Set-Content out/Release/args.gn -Encoding utf8
    gn.bat gen out/Release --fail-on-unused-args
    autoninja.bat -C out/Release libEGL_static libGLESv2_static

    # Include SDK imports from every dependency whose objects may be linked.
    $targets = @('//:libEGL_static', '//:libGLESv2_static')
    $dependencyClosure = foreach ($target in $targets) {
        $target
        $description = gn.bat desc out/Release $target deps --all --format=json |
            Out-String | ConvertFrom-Json -AsHashtable
        if (-not $description.Contains($target)) {
            throw "GN did not describe dependencies for $target."
        }
        $description[$target].deps
    }
    $librariesByTarget = gn.bat desc out/Release '//*' libs --format=json |
        Out-String | ConvertFrom-Json -AsHashtable
    $linkLibraries = @($dependencyClosure | Sort-Object -Unique | ForEach-Object {
        if ($librariesByTarget.Contains($_)) {
            $librariesByTarget[$_].libs
        }
    } | Where-Object { $_ } | Sort-Object -Unique)
    $builtinsPattern = '^//third_party/llvm-build/Release[+]Asserts/lib/clang/[^/]+/lib/windows/clang_rt[.]builtins-x86_64[.]lib$'
    $builtins = @($linkLibraries | Where-Object { $_ -cmatch $builtinsPattern })
    if ($builtins.Count -gt 1) { throw 'GN reported multiple x64 Clang builtins archives.' }
    $systemLibs = @($linkLibraries | Where-Object { $_ -cnotmatch $builtinsPattern })
    if (-not $systemLibs.Count) { throw 'GN reported no Windows link libraries.' }

    foreach ($lib in $systemLibs) {
        if ($lib -notmatch '^[\w.-]+$') { throw "Nonportable link dependency: $lib" }
    }

    $stage = Join-Path $dist 'package'
    if (Test-Path -LiteralPath $stage) {
        if ((Resolve-Path -LiteralPath $stage).Path -ne $stage -or
            (Get-Item -LiteralPath $stage).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -or
            (Get-Item -LiteralPath $dist).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            throw "Unsafe package staging path: $stage"
        }
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    New-Item -ItemType Directory -Force (Join-Path $stage 'lib') | Out-Null
    foreach ($name in @('libEGL_static.lib', 'libGLESv2_static.lib')) {
        $archiveFiles = @(Get-ChildItem out/Release -Recurse -File -Filter $name)
        if ($archiveFiles.Count -ne 1) { throw "Expected one $name, found $($archiveFiles.Count)." }
        $sourceArchive = $archiveFiles[0].FullName
        $destination = Join-Path $stage "lib/$name"
        if ($name -eq 'libGLESv2_static.lib' -and $builtins.Count) {
            # Flatten both COFF archives so MSVC consumers need only the packaged libs.
            $runtime = Join-Path $angle $builtins[0].Substring(2)
            $toolset = (Get-Content -Raw (Join-Path $vs 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt')).Trim()
            $msvcLib = Join-Path $vs "VC/Tools/MSVC/$toolset/bin/Hostx64/x64/lib.exe"
            $gccPersonality = '(^|[\\/])gcc_personality_v0[.]c[.]obj$'
            $members = @(& $msvcLib /nologo /list $runtime | ForEach-Object { $_.Trim() } |
                Where-Object { $_ -match $gccPersonality })
            if ($members.Count) {
                # This object requires the GCC unwinder, which MSVC does not provide.
                $filtered = Join-Path $angle 'out/Release/clang-builtins-msvc.lib'
                $remove = @($members | ForEach-Object { "/remove:$_" })
                & $msvcLib /nologo "/out:$filtered" @remove $runtime
                $remaining = & $msvcLib /nologo /list $filtered
                if ($remaining -match $gccPersonality) { throw 'GCC personality object remained in Clang builtins.' }
                $runtime = $filtered
            }
            $librarian = Join-Path $angle 'third_party/llvm-build/Release+Asserts/bin/lld-link.exe'
            & $librarian /lib /nologo "/out:$destination" $sourceArchive $runtime
            $packagedMembers = & $librarian /lib /nologo /list $destination
            if (-not ($packagedMembers -match '(^|[\\/])libGLESv2_autogen[.]obj$')) {
                throw 'The merged archive is missing the GLES entry point object.'
            }
        } else {
            Copy-Item -LiteralPath $sourceArchive -Destination $destination
        }
        $archive = [IO.File]::OpenRead($destination)
        try {
            $header = [byte[]]::new(8)
            if ($archive.Read($header, 0, 8) -ne 8 -or
                [Text.Encoding]::ASCII.GetString($header) -cne "!<arch>`n") {
                throw "$name is not a regular COFF archive."
            }
        } finally {
            $archive.Dispose()
        }
    }
    Copy-Item include -Destination $stage -Recurse
    Copy-Item LICENSE -Destination $stage
    if ($builtins.Count) {
        Add-Content (Join-Path $stage 'LICENSE') ""
        Get-Content -Raw (Join-Path $root 'licenses/compiler-rt.txt') |
            Add-Content (Join-Path $stage 'LICENSE')
    }
    @"
ANGLE SHA: $Revision
Chromium build SHA: $buildRevision
Built UTC: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
Platform: Windows x64, Release
CRT: /MD
Defines: ANGLE_STATIC=1 ANGLE_EXPORT= EGLAPI= GL_APICALL= GL_API=
Windows libraries: $($systemLibs -join ' ')

GN args:
$gnArgs
"@ | Set-Content (Join-Path $stage 'BUILD_INFO.txt') -Encoding utf8

    $zipName = 'angle-windows-x64-static.zip'
    $zip = Join-Path $dist $zipName
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
    $sha256 = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    "$sha256  $zipName" | Set-Content "$zip.sha256" -Encoding ascii
} finally {
    Pop-Location
}
