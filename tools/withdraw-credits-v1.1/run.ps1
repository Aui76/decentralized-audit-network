# Run Organ 1 withdraw-credits checker (v1.1.0) on a pinned target.
# Usage: cd body/tools/withdraw-credits-v1.1
#   $env:TARGET_ADDRESS="0x..."; .\run.ps1

$ErrorActionPreference = "Stop"
$Cell = Resolve-Path "..\..\..\cell"
if (-not $env:TARGET_ADDRESS) { Write-Error "Set TARGET_ADDRESS to the pinned Gate0R2Target (or fix) on chain." }
if (-not $env:RPC_URL) {
    $envPath = Join-Path $Cell ".env"
    if (Test-Path $envPath) {
        Get-Content $envPath | ForEach-Object {
            if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
            if ($_ -match '^BASE_SEPOLIA_RPC_URL=') { $env:RPC_URL = ($_ -split '=', 2)[1].Trim() }
        }
    }
    if (-not $env:RPC_URL) { $env:RPC_URL = "https://sepolia.base.org" }
}
Set-Location $Cell
forge script script/tools/RunWithdrawCreditsV1.s.sol:RunWithdrawCreditsV1 --rpc-url $env:RPC_URL
