# --- tbl4-ai-stack Setup Tests (Windows) ---------------------------------------
# Regression tests for the .env handling in setup_windows.ps1.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test_setup_windows.ps1
#
# No Pester dependency on purpose: the in-box Pester on Windows 10/11 is 3.4.0,
# whose syntax differs from Pester 5, and the whole point of this file is that
# it runs anywhere a student can run setup. Exit code 0 = all passed.
#
# These tests exist because of a real classroom failure: setup_windows.ps1 read
# .env with Get-Content (which Windows PowerShell 5.1 decodes as the ANSI
# codepage for a BOM-less file) and wrote it back with WriteAllText (UTF-8).
# Every call re-encoded each non-ASCII byte into a longer sequence, so .env grew
# ~2.2x per call and ~5x per setup run. A student who re-ran setup half a dozen
# times while fixing unrelated problems ended up with a .env of nearly 2 GB, and
# setup died with OutOfMemoryException on what looked like a trivial 2 KB write.
# Test-EnvDoesNotGrow is the one that would have caught it.

$ErrorActionPreference = "Stop"

$RepoRoot   = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }
$SetupPath  = Join-Path $RepoRoot "setup_windows.ps1"
$ExamplePath = Join-Path $RepoRoot ".env.example"
$SandboxRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("tbl4-tests-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8))

$script:Passed = 0
$script:Failed = 0

function Ok($msg)   { Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Bad($msg)  { Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Head($msg) { Write-Host ""; Write-Host $msg -ForegroundColor Cyan }

function Assert-True($name, $condition, $detail) {
    if ($condition) { $script:Passed++; Ok $name }
    else { $script:Failed++; Bad $name; if ($detail) { Write-Host "         $detail" -ForegroundColor Red } }
}

function Assert-Equal($name, $expected, $actual) {
    Assert-True $name ($expected -eq $actual) "expected [$expected], got [$actual]"
}

# --- Harness -----------------------------------------------------------------
# Run setup's .env logic without Docker, Ollama, or the network by slicing the
# real script at the Docker section. Slicing the shipped file (rather than
# copying the logic here) means these tests fail if setup regresses -- which is
# the entire point.
$DockerMarker = "# --- Docker ---"

function New-Sandbox {
    param([string]$Name, [switch]$NoExample)

    $dir = Join-Path $SandboxRoot $Name
    $null = [System.IO.Directory]::CreateDirectory($dir)

    $src = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($SetupPath))
    # Strip the BOM before re-adding one below; two BOMs make PowerShell choke
    # on line 1 with "the term 'Windows' is not recognized".
    if ($src.Length -gt 0 -and $src[0] -eq [char]0xFEFF) { $src = $src.Substring(1) }
    $cut = $src.IndexOf($DockerMarker)
    if ($cut -lt 0) { throw "Marker '$DockerMarker' not found in setup_windows.ps1 - update the test harness." }

    # Report what setup resolved, so tests can assert on it.
    $probe = @'

$probe = Get-EnvSettings $EnvPath
$report = @(
    "PROFILES=$Profiles"
    "MODEL=$Model"
    "WEBUI_PORT=$WebuiPort"
    "N8N_PORT=$N8nPort"
    "SIZE=$((Get-Item -LiteralPath $EnvPath).Length)"
    "BAK=$(Test-Path -LiteralPath ($EnvPath + '.bak'))"
) + ($probe.Keys | Sort-Object | ForEach-Object { "ENV.$_=$($probe[$_])" })
[System.IO.File]::WriteAllText((Join-Path $RepoRoot "probe.txt"), ($report -join "`n"))
'@
    [System.IO.File]::WriteAllText(
        (Join-Path $dir "setup_windows.ps1"),
        ($src.Substring(0, $cut) + $probe),
        (New-Object System.Text.UTF8Encoding($true)))

    if (-not $NoExample) { Copy-Item -LiteralPath $ExamplePath -Destination (Join-Path $dir ".env.example") -Force }
    return $dir
}

function Invoke-Setup([string]$Dir) {
    # Lower EAP for the call: under 'Stop' any stderr write from a native exe
    # becomes a terminating NativeCommandError, which would abort the test run
    # instead of letting us assert on the child's output.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dir "setup_windows.ps1") 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prevEAP }
    $probeFile = Join-Path $Dir "probe.txt"
    $probe = @{}
    if (Test-Path -LiteralPath $probeFile) {
        foreach ($line in ([System.IO.File]::ReadAllText($probeFile) -split "`n")) {
            if ($line -match '^([^=]+)=(.*)$') { $probe[$matches[1]] = $matches[2] }
        }
        Remove-Item -LiteralPath $probeFile -Force
    }
    return [pscustomobject]@{
        Output   = ($out | Out-String)
        ExitCode = $code
        Probe    = $probe
    }
}

function Get-EnvSize([string]$Dir) { (Get-Item -LiteralPath (Join-Path $Dir ".env")).Length }

# Reproduce a .env damaged by the pre-fix encoding bug: ASCII settings survive
# intact, comment lines balloon into mojibake. One giant line rather than many,
# which is what the real bug produced and what makes ReadLine() dangerous.
function New-CorruptEnv {
    param([string]$Path, [int]$JunkBytes, [System.Collections.IDictionary]$Settings)

    $sb = New-Object System.Text.StringBuilder
    # The CP1252 reading of a UTF-8 box-drawing character (C3 A2 E2 80 AC C2).
    $unit = [char]0x00C3 + [char]0x00A2 + [char]0x00E2 + [char]0x20AC + [char]0x00C2
    [void]$sb.Append("# ")
    while ($sb.Length -lt $JunkBytes) { [void]$sb.Append($unit) }
    [void]$sb.Append("`n")
    foreach ($k in $Settings.Keys) { [void]$sb.Append("$k=$($Settings[$k])`n") }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

# --- Tests -------------------------------------------------------------------

function Test-ScriptParses {
    Head "setup_windows.ps1 is syntactically valid"
    $errs = $null
    $null = [System.Management.Automation.PSParser]::Tokenize(
        [System.IO.File]::ReadAllText($SetupPath), [ref]$errs)
    Assert-True "parses without error" ($errs.Count -eq 0) (($errs | ForEach-Object { "line $($_.Token.StartLine): $($_.Message)" }) -join "; ")
}

function Test-ExampleIsAscii {
    Head ".env.example is pure ASCII"
    # Defense in depth. With no non-ASCII bytes in the template there is nothing
    # for an encoding mismatch to amplify, so the growth bug cannot come back
    # through a decorative box-drawing rule someone adds later.
    $bytes = [System.IO.File]::ReadAllBytes($ExamplePath)
    $high = @($bytes | Where-Object { $_ -gt 127 })
    Assert-True "no bytes above 0x7F" ($high.Count -eq 0) "$($high.Count) non-ASCII byte(s) found"
    Assert-True "no UTF-8 BOM" -condition (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) -detail ""
}

function Test-FreshInstall {
    Head "Fresh install"
    $dir = New-Sandbox "fresh"
    $r = Invoke-Setup $dir

    Assert-True  "creates .env" (Test-Path -LiteralPath (Join-Path $dir ".env")) ""
    Assert-True  "reports creation" ($r.Output -match "Created \.env from \.env\.example") ""
    Assert-Equal "PROFILES defaults to local" "local" $r.Probe["PROFILES"]
    Assert-Equal "MODEL defaults to llama3.2" "llama3.2" $r.Probe["MODEL"]
    Assert-Equal "WEBUI_PORT defaults to 3000" "3000" $r.Probe["WEBUI_PORT"]
    Assert-Equal "local profile points at host.docker.internal" "http://host.docker.internal:11434" $r.Probe["ENV.OLLAMA_BASE_URL"]

    $secret = $r.Probe["ENV.WEBUI_SECRET_KEY"]
    Assert-True "generates a 64-char hex WEBUI_SECRET_KEY" ($secret -match '^[0-9a-f]{64}$') "got [$secret]"
}

function Test-EnvIsUtf8NoBom {
    Head ".env is written as UTF-8 without a BOM"
    $dir = New-Sandbox "encoding"
    $r = Invoke-Setup $dir
    if (-not (Test-Path -LiteralPath (Join-Path $dir ".env"))) {
        Assert-True "setup produced a .env" $false $r.Output
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $dir ".env"))
    Assert-True "no BOM" -condition (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) -detail ""
    # Strict UTF-8 decode must succeed, i.e. the file is not ANSI-encoded.
    $strict = New-Object System.Text.UTF8Encoding($false, $true)
    $decoded = $true
    try { $null = $strict.GetString($bytes) } catch { $decoded = $false }
    Assert-True "decodes as strict UTF-8" $decoded "file is not valid UTF-8"
}

function Test-EnvDoesNotGrow {
    Head "REGRESSION: .env does not grow across repeated runs"
    # The original bug. Six runs of the old code took .env from 2 KB to ~1 GB.
    $dir = New-Sandbox "repeat"
    $first = Invoke-Setup $dir
    $baseline = Get-EnvSize $dir
    $secret = $first.Probe["ENV.WEBUI_SECRET_KEY"]

    $sizes   = @($baseline)
    $secrets = @($secret)
    foreach ($i in 1..6) {
        $r = Invoke-Setup $dir
        $sizes   += (Get-EnvSize $dir)
        $secrets += $r.Probe["ENV.WEBUI_SECRET_KEY"]
    }
    Assert-True "size identical across 7 runs" `
        (@($sizes | Where-Object { $_ -ne $baseline }).Count -eq 0) "sizes: $($sizes -join ' -> ')"
    Assert-True "secret preserved across 7 runs" `
        (@($secrets | Where-Object { $_ -ne $secret }).Count -eq 0) "secrets diverged: $($secrets -join ', ')"
}

function Test-RoundTripIsStable {
    Head "REGRESSION: Set-EnvVars is byte-stable under repeated calls"
    # The tightest form of the original bug: dot-source the shipped helpers and
    # hammer the write path directly. The old code grew the file ~2.2x per call,
    # so 20 calls took a 2 KB .env past 2 GB. This fails in seconds instead of
    # waiting for a full setup run to notice.
    $dir = New-Sandbox "roundtrip"
    $savedRoot = $RepoRoot
    Push-Location -LiteralPath $dir
    try {
        . (Join-Path $dir "setup_windows.ps1") *> $null
        $target = Join-Path $dir ".env"
        $update = @{ OLLAMA_BASE_URL = "http://ollama:11434"; OLLAMA_HOST = "http://ollama:11434" }
        # Baseline AFTER the first call: that one legitimately changes the file
        # (the URL swap is 28 bytes shorter). What must never change is the size
        # from one identical rewrite to the next.
        Set-EnvVars $update
        $baseline = (Get-Item -LiteralPath $target).Length
        $sizes = @()
        foreach ($i in 1..20) {
            Set-EnvVars $update
            $sizes += (Get-Item -LiteralPath $target).Length
        }
        Assert-True "20 rewrites leave the size unchanged" `
            (@($sizes | Where-Object { $_ -ne $baseline }).Count -eq 0) `
            "baseline $baseline, observed: $(($sizes | Select-Object -Unique) -join ', ')"
        Assert-True "file stays strict UTF-8" `
            (& { try { $null = (New-Object System.Text.UTF8Encoding($false, $true)).GetString([System.IO.File]::ReadAllBytes($target)); $true } catch { $false } }) ""
    } finally {
        Pop-Location
        Set-Variable -Name RepoRoot -Value $savedRoot -Scope Script
    }
}

function Test-ProfileSwitch {
    Head "Profile switch rewrites the Ollama URL"
    $dir = New-Sandbox "profiles"
    $null = Invoke-Setup $dir
    $envPath = Join-Path $dir ".env"
    $text = [System.IO.File]::ReadAllText($envPath)
    [System.IO.File]::WriteAllText($envPath, ($text -replace '(?m)^PROFILES=.*', 'PROFILES=cloud,mcp'),
        (New-Object System.Text.UTF8Encoding($false)))

    $r = Invoke-Setup $dir
    Assert-Equal "PROFILES read back" "cloud,mcp" $r.Probe["PROFILES"]
    Assert-Equal "cloud profile points at the container" "http://ollama:11434" $r.Probe["ENV.OLLAMA_BASE_URL"]
    Assert-Equal "OLLAMA_HOST follows" "http://ollama:11434" $r.Probe["ENV.OLLAMA_HOST"]
    Assert-True  "no growth after a profile switch" ((Get-EnvSize $dir) -lt 8192) "size $(Get-EnvSize $dir)"
}

function Test-RepairsBloatedEnv {
    Head "Repairs a .env wrecked by the old encoding bug"
    # 40 MB in a single comment line: large enough to trip the size check and
    # to prove the salvage path never materialises the line (ReadLine on this
    # is what would re-trigger the OutOfMemoryException we are recovering from).
    $dir = New-Sandbox "bloated"
    New-CorruptEnv -Path (Join-Path $dir ".env") -JunkBytes (40MB) -Settings ([ordered]@{
        PROFILES          = "cloud,mcp"
        MODEL             = "mistral"
        WEBUI_PORT        = "8080"
        N8N_PORT          = "5678"
        WEBUI_SECRET_KEY  = "deadbeefcafe1234"
    })
    $before = Get-EnvSize $dir
    Assert-True "corrupt fixture is oversized" ($before -gt 20MB) "size $before"

    $r = Invoke-Setup $dir
    Assert-True  "reports the damage" ($r.Output -match "damaged by an earlier version") ""
    Assert-True  "rebuilds to a sane size" ((Get-EnvSize $dir) -lt 8192) "size $(Get-EnvSize $dir)"
    Assert-Equal "keeps PROFILES" "cloud,mcp" $r.Probe["PROFILES"]
    Assert-Equal "keeps MODEL" "mistral" $r.Probe["MODEL"]
    Assert-Equal "keeps WEBUI_PORT" "8080" $r.Probe["WEBUI_PORT"]
    Assert-Equal "keeps WEBUI_SECRET_KEY" "deadbeefcafe1234" $r.Probe["ENV.WEBUI_SECRET_KEY"]
    Assert-Equal "drops the multi-MB backup" "False" $r.Probe["BAK"]

    # And the rebuilt file must itself be stable.
    $after = Get-EnvSize $dir
    $null = Invoke-Setup $dir
    Assert-Equal "repair is idempotent" $after (Get-EnvSize $dir)
}

function Test-RepairsMojibakeEnv {
    Head "Repairs a small mojibake .env and keeps a backup"
    $dir = New-Sandbox "mojibake"
    # One ANSI-read / UTF8-write cycle: the classic first-generation damage.
    Copy-Item -LiteralPath (Join-Path $dir ".env.example") -Destination (Join-Path $dir ".env") -Force
    Push-Location -LiteralPath $dir
    try {
        $lines = Get-Content .env
        [System.IO.File]::WriteAllText((Join-Path $dir ".env"), (($lines -join "`n") + "`n"))
    } finally { Pop-Location }

    # .env.example is ASCII now, so a single cycle is lossless and there is
    # nothing to repair -- which is exactly the hardening working. Inject
    # explicit mojibake to exercise the detector.
    $envPath = Join-Path $dir ".env"
    $text = [System.IO.File]::ReadAllText($envPath)
    $mojibake = "# " + ([string]([char]0x00C3 + [char]0x00A2 + [char]0x00E2 + [char]0x20AC) * 40) + "`n"
    [System.IO.File]::WriteAllText($envPath, ($mojibake + $text), (New-Object System.Text.UTF8Encoding($false)))

    $r = Invoke-Setup $dir
    Assert-True  "detects mojibake below the size threshold" ($r.Output -match "damaged by an earlier version") ""
    Assert-Equal "keeps a .env.bak for a small file" "True" $r.Probe["BAK"]
    Assert-True  "rebuilt file is clean ASCII-safe" ((Get-EnvSize $dir) -lt 8192) "size $(Get-EnvSize $dir)"
}

function Test-PreservesRegexMetacharacters {
    Head "Values containing regex metacharacters survive a rewrite"
    # The old code assigned via -replace, so a value holding $1 or $& was
    # expanded as a backreference and silently corrupted.
    $dir = New-Sandbox "metachars"
    New-CorruptEnv -Path (Join-Path $dir ".env") -JunkBytes (128KB) -Settings ([ordered]@{
        PROFILES         = "local"
        MODEL            = "llama3.2"
        N8N_ENCRYPTION_KEY = 'abc$1def$&ghi$$jkl'
        WEBUI_SECRET_KEY = "0123456789abcdef"
    })
    $r = Invoke-Setup $dir
    Assert-Equal "value preserved byte for byte" 'abc$1def$&ghi$$jkl' $r.Probe["ENV.N8N_ENCRYPTION_KEY"]
}

function Test-HandlesCrlf {
    Head "A CRLF .env is handled without duplicating keys"
    $dir = New-Sandbox "crlf"
    $text = [System.IO.File]::ReadAllText($ExamplePath) -replace "`r`n", "`n" -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $dir ".env"), $text, (New-Object System.Text.UTF8Encoding($false)))

    $r = Invoke-Setup $dir
    Assert-Equal "OLLAMA_BASE_URL rewritten once" "http://host.docker.internal:11434" $r.Probe["ENV.OLLAMA_BASE_URL"]
    $count = ([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $dir ".env")), '(?m)^OLLAMA_BASE_URL=')).Count
    Assert-Equal "exactly one OLLAMA_BASE_URL line" 1 $count
}

function Test-WildcardPath {
    Head "Runs from a folder whose name contains [] and ()"
    # Resolve-Path treats [] as a wildcard pattern; Windows also auto-suffixes
    # re-downloads as "tbl4-ai-stack-master (2)".
    $dir = New-Sandbox "wild [1] (2)"
    $r = Invoke-Setup $dir
    Assert-True  "setup completes" (Test-Path -LiteralPath (Join-Path $dir ".env")) $r.Output
    Assert-Equal "settings resolve" "local" $r.Probe["PROFILES"]
}

function Test-MissingExample {
    Head "Missing .env.example fails with guidance, not a stack trace"
    $dir = New-Sandbox "no-example" -NoExample
    $r = Invoke-Setup $dir
    Assert-Equal "exits 1" 1 $r.ExitCode
    Assert-True  "names the folder and explains the nested-ZIP case" `
        (($r.Output -match "\.env\.example is missing") -and ($r.Output -match "nested folder")) $r.Output
    Assert-True  "no raw .NET exception text" (-not ($r.Output -match "Exception|at System\.")) $r.Output
}

# --- Run ---------------------------------------------------------------------
Write-Host ""
Write-Host "========================================="
Write-Host "  tbl4-ai-stack - setup_windows.ps1 tests"
Write-Host "========================================="

$null = [System.IO.Directory]::CreateDirectory($SandboxRoot)
$Tests = @(
    "Test-ScriptParses"
    "Test-ExampleIsAscii"
    "Test-FreshInstall"
    "Test-EnvIsUtf8NoBom"
    "Test-EnvDoesNotGrow"
    "Test-RoundTripIsStable"
    "Test-ProfileSwitch"
    "Test-RepairsBloatedEnv"
    "Test-RepairsMojibakeEnv"
    "Test-PreservesRegexMetacharacters"
    "Test-HandlesCrlf"
    "Test-WildcardPath"
    "Test-MissingExample"
)
try {
    # Each test is isolated: a regression bad enough to throw should show up as
    # a red test, not abort the run and hide everything after it.
    foreach ($test in $Tests) {
        try { & $test }
        catch {
            $script:Failed++
            Bad "$test threw: $($_.Exception.Message)"
        }
    }
} finally {
    Remove-Item -LiteralPath $SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "========================================="
if ($script:Failed -eq 0) {
    Write-Host "  All $script:Passed checks passed." -ForegroundColor Green
    Write-Host "========================================="
    Write-Host ""
    exit 0
} else {
    Write-Host "  $script:Failed failed, $script:Passed passed." -ForegroundColor Red
    Write-Host "========================================="
    Write-Host ""
    exit 1
}
