$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$SubmoduleDir = Join-Path $RepoRoot "core\Clash.Meta"
$PatchFile = Join-Path $RepoRoot "core\patches\mihomo-fixes.patch"

if (-not (Test-Path $SubmoduleDir)) {
    Write-Error "Submodule directory $SubmoduleDir does not exist."
    exit 1
}

if (-not (Test-Path $PatchFile)) {
    Write-Error "Patch file $PatchFile not found."
    exit 1
}

$canApply = & git -C $SubmoduleDir apply --check $PatchFile 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "Applying Mihomo companion patch to $SubmoduleDir..."
    & git -C $SubmoduleDir apply $PatchFile
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to apply Mihomo patch."
        exit 1
    }
    Write-Host "Successfully applied Mihomo companion patch."
} else {
    $isApplied = & git -C $SubmoduleDir apply --reverse --check $PatchFile 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Mihomo companion patch is already applied in $SubmoduleDir."
    } else {
        Write-Error "Submodule has conflicts or cannot apply Mihomo companion patch cleanly."
        exit 1
    }
}
