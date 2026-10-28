param(
    [Parameter(Mandatory=$true)][string]$Script,
    [switch]$Windowless,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$candidates = @()
foreach ($name in @('py.exe', 'python.exe')) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) {
        $prefix = @()
        if ($name -eq 'py.exe') { $prefix = @('-3') }
        $candidates += [pscustomobject]@{ Path=$command.Source; Prefix=$prefix }
    }
}
foreach ($base in @((Join-Path $env:LOCALAPPDATA 'Programs\Python'), $env:ProgramFiles)) {
    if (Test-Path -LiteralPath $base) {
        Get-ChildItem -LiteralPath $base -Directory -Filter 'Python*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | ForEach-Object {
                $path = Join-Path $_.FullName 'python.exe'
                if (Test-Path -LiteralPath $path) {
                    $candidates += [pscustomobject]@{ Path=$path; Prefix=@() }
                }
            }
    }
}
foreach ($candidate in $candidates) {
    $executable = $candidate.Path
    $prefix = @($candidate.Prefix)
    try {
        & $executable @prefix -c "import sys, struct, tkinter; assert sys.version_info >= (3, 10) and struct.calcsize('P') == 8" 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        $arguments = @($prefix) + @($Script)
        if ($Uninstall) { $arguments += '--uninstall' }
        if ($Windowless) {
            $pythonw = Join-Path (Split-Path $executable) 'pythonw.exe'
            if ((Split-Path $executable -Leaf) -eq 'py.exe') {
                $pythonw = Join-Path (Split-Path $executable) 'pyw.exe'
            }
            if (Test-Path -LiteralPath $pythonw) { $executable = $pythonw }
            $quoted = $arguments | ForEach-Object { '"' + $_ + '"' }
            Start-Process -FilePath $executable -ArgumentList $quoted -WorkingDirectory (Split-Path $Script) -WindowStyle Hidden
            exit 0
        }
        & $executable @arguments
        exit $LASTEXITCODE
    } catch { continue }
}
Write-Host '64-bit Python 3.10 or newer with Tkinter is required.'
Write-Host 'Install it from https://www.python.org/downloads/windows/ and try again.'
exit 1
