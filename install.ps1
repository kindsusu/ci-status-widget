# 바탕화면 바로가기를 만들고, -Startup이면 로그인할 때 자동 실행되게 시작 프로그램에도 넣는다.
# 제거: -Uninstall
param([switch]$Startup, [switch]$Uninstall)

$name = 'CI 현황.lnk'
$targets = @((Join-Path ([Environment]::GetFolderPath('Desktop')) $name), (Join-Path ([Environment]::GetFolderPath('Startup')) $name))

if ($Uninstall) {
    $targets | Where-Object { Test-Path $_ } | ForEach-Object { Remove-Item $_; "삭제: $_" }
    exit
}
if (-not (Test-Path (Join-Path $PSScriptRoot 'config.json'))) {
    Copy-Item (Join-Path $PSScriptRoot 'config.example.json') (Join-Path $PSScriptRoot 'config.json')
    "config.json을 만들었습니다. 조직(org)과 저장소(repos)를 적은 뒤 실행하세요: $(Join-Path $PSScriptRoot 'config.json')"
}

$shell = New-Object -ComObject WScript.Shell
foreach ($path in $(if ($Startup) { $targets } else { $targets[0] })) {
    $s = $shell.CreateShortcut($path)
    $s.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $s.Arguments = "-NoProfile -WindowStyle Hidden -File `"$(Join-Path $PSScriptRoot 'ci-widget.ps1')`""
    $s.WorkingDirectory = $PSScriptRoot
    $s.IconLocation = "$env:WINDIR\System32\imageres.dll,144"
    $s.Save()
    "만듦: $path"
}
