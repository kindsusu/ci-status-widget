# CI 현황 팝업: config.json에 적은 저장소들의 진행 중·최근 완료 GitHub Actions 실행을 항상 위에 띄워 둔다.
# 실행: 바탕화면 'CI 현황' 바로가기(install.ps1이 만든다). 행을 더블클릭하거나 Enter를 누르면 GitHub 실행 화면이 열린다.
# '미니 모드'는 진행 중·대기 건수만 보이는 작은 막대로 접는다(끌어서 옮기고, 두 번 클릭하면 펼침).
# 마지막 모드는 기억해서 다음 실행 때 그대로 연다.
# 작업표시줄 오른쪽(알림 영역 바로 왼쪽)에도 진행 중·대기 건수 막대를 붙인다. 막대를 클릭하면 창을 열고 닫고,
# 오른쪽 클릭 메뉴에서 새로고침·종료한다. 창의 X는 종료가 아니라 숨기기다.
# -Snapshot <png>: 한 번 조회해 창 화면만 저장하고 끝낸다(확인용). -Mini: 미니 모드로 시작.
param([string]$Snapshot, [switch]$Mini)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
# 어두운 제목 표시줄·스크롤바(Windows 10 20H1 이상, 실패해도 무시)
Add-Type -Namespace CiWidget -Name Native -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
[DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr h, string app, string idList);
[DllImport("user32.dll")] public static extern bool ReleaseCapture();
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string name);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string name);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
[DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int index, IntPtr value);
[DllImport("user32.dll")] public static extern IntPtr SetParent(IntPtr child, IntPtr parent);
[DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll", SetLastError = true)] public static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dst, IntPtr pptDst, ref SIZE size, IntPtr src, ref POINT pptSrc, uint key, ref BLENDFUNCTION blend, uint flags);
[DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
[DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
[DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
[DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
[DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
[DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
[DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFOHEADER bi, uint usage, out IntPtr bits, IntPtr section, uint offset);
public struct SIZE { public int cx, cy; }
public struct POINT { public int x, y; }
public struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
public struct BITMAPINFOHEADER { public int biSize, biWidth, biHeight; public short biPlanes, biBitCount; public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant; }
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
public struct RECT { public int Left, Top, Right, Bottom; }
'@
$modeFile = Join-Path $env:LOCALAPPDATA 'ci-widget.mode'

# 조직·저장소는 config.json에 둔다(저장소에는 config.example.json만 올린다)
$cfgPath = Join-Path $PSScriptRoot 'config.json'
if (-not (Test-Path $cfgPath)) {
    [void][Windows.Forms.MessageBox]::Show("config.json이 없습니다.`nconfig.example.json을 config.json으로 복사해 조직과 저장소를 적어 주세요.`n`n$cfgPath", 'CI 현황')
    exit 1
}
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$Org = [string]$cfg.org
$Repos = @($cfg.repos)
$RefreshSec = if ($cfg.refreshSeconds) { [int]$cfg.refreshSeconds } else { 180 }
$DoneCount = 20

# 두 번 띄우면 조회만 두 배가 되므로 하나만 둔다
$mutex = New-Object Threading.Mutex($false, 'Local\CiStatusWidget')
# 두 번째 실행은 이미 떠 있는 위젯에 '창 열기' 신호만 보내고 끝낸다(숨긴 창을 바로가기로 다시 열 수 있게)
$showSignal = New-Object Threading.EventWaitHandle($false, 'AutoReset', 'Local\CiStatusWidget.Show')
if (-not $Snapshot -and -not $mutex.WaitOne(0)) { [void]$showSignal.Set(); exit }
$hiddenFile = Join-Path $env:LOCALAPPDATA 'ci-widget.hidden'   # 있으면 다음 실행 때 숨긴 채로 시작

# gh 조회는 별도 실행 공간에서 돌려 창이 멈추지 않게 한다
$fetch = {
    param($Org, $Repos)
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    foreach ($r in $Repos) {
        $json = gh run list --repo "$Org/$r" --limit 10 --json name,displayTitle,headBranch,status,conclusion,createdAt,updatedAt,url 2>$null
        if ($LASTEXITCODE) { [pscustomobject]@{ repo = $r; error = $true }; continue }
        foreach ($x in (ConvertFrom-Json ($json -join "`n"))) { $x | Add-Member repo $r -PassThru }
    }
}

# 색 토큰(어두운 개발 도구 팔레트, 글자 대비 4.5:1 이상)
function C($hex) { [Drawing.ColorTranslator]::FromHtml($hex) }
$T = @{
    bg = C '#0F172A'; surface = C '#162033'; selected = C '#26344D'; border = C '#2A3850'
    fg = C '#F1F5F9'; muted = C '#94A3B8'
    running = C '#38BDF8'; queued = C '#FBBF24'; success = C '#4ADE80'; failure = C '#F87171'; neutral = C '#94A3B8'
}
# 상태 → (표시 이름, 색, 속이 빈 점 여부). 색만으로 구분하지 않도록 항상 글자를 같이 쓴다
$State = @{
    queued = '대기', 'queued', $true; waiting = '대기', 'queued', $true; pending = '대기', 'queued', $true
    in_progress = '실행 중', 'running', $false
    success = '성공', 'success', $false; failure = '실패', 'failure', $false; timed_out = '시간 초과', 'failure', $false
    cancelled = '취소', 'neutral', $true; skipped = '건너뜀', 'neutral', $true
}

$fontBody = New-Object Drawing.Font('Malgun Gothic', 9.5)
$fontBold = New-Object Drawing.Font('Malgun Gothic', 9.5, [Drawing.FontStyle]::Bold)
$fontTitle = New-Object Drawing.Font('Malgun Gothic', 12.5, [Drawing.FontStyle]::Bold)
$fontSection = New-Object Drawing.Font('Malgun Gothic', 8.5, [Drawing.FontStyle]::Bold)
$fontNum = New-Object Drawing.Font('Consolas', 9.5)   # 시각·시간은 고정폭으로 줄을 맞춘다
$fontStrip = New-Object Drawing.Font('Malgun Gothic', 8.5, [Drawing.FontStyle]::Bold)
$fontStripTitle = New-Object Drawing.Font('Malgun Gothic', 10, [Drawing.FontStyle]::Bold)
$TF = [Windows.Forms.TextFormatFlags]
$flags = $TF::SingleLine -bor $TF::VerticalCenter -bor $TF::EndEllipsis -bor $TF::NoPrefix

$form = New-Object Windows.Forms.Form -Property @{
    Text = 'CI 현황'; TopMost = $true; Font = $fontBody; Size = '900,500'; MinimumSize = '720,260'
    BackColor = $T.bg; ForeColor = $T.fg
}
$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.StartPosition = 'Manual'
$form.Location = New-Object Drawing.Point(($wa.Right - $form.Width - 12), ($wa.Bottom - $form.Height - 12))

# 머리: 제목·갱신 시각·요약 칩은 직접 그리고, 버튼만 컨트롤로 둔다
$head = New-Object Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 78; BackColor = $T.bg }
$btn = New-Object Windows.Forms.Button -Property @{
    Text = '새로고침'; Size = '92,30'; FlatStyle = 'Flat'; BackColor = $T.surface; ForeColor = $T.fg
    Anchor = 'Top,Right'; Cursor = [Windows.Forms.Cursors]::Hand
}
$btn.FlatAppearance.BorderColor = $T.border
$btn.FlatAppearance.MouseOverBackColor = $T.selected
$pin = New-Object Windows.Forms.CheckBox -Property @{
    Text = '항상 위'; Checked = $true; AutoSize = $true; ForeColor = $T.muted; FlatStyle = 'Flat'
    Anchor = 'Top,Right'; Cursor = [Windows.Forms.Cursors]::Hand
}
$miniBtn = New-Object Windows.Forms.Button -Property @{
    Text = '미니 모드'; Size = '92,30'; FlatStyle = 'Flat'; BackColor = $T.surface; ForeColor = $T.fg
    Anchor = 'Top,Right'; Cursor = [Windows.Forms.Cursors]::Hand
}
$hideBtn = New-Object Windows.Forms.Button -Property @{
    Text = '숨기기'; Size = '72,30'; FlatStyle = 'Flat'; BackColor = $T.surface; ForeColor = $T.fg
    Anchor = 'Top,Right'; Cursor = [Windows.Forms.Cursors]::Hand
}
foreach ($b in $btn, $miniBtn, $hideBtn) { $b.FlatAppearance.BorderColor = $T.border; $b.FlatAppearance.MouseOverBackColor = $T.selected }
$head.Controls.AddRange(@($btn, $pin, $miniBtn, $hideBtn))
function Place-Head {
    $btn.Location = New-Object Drawing.Point(($head.Width - $btn.Width - 14), 12)
    $pin.Location = New-Object Drawing.Point(($btn.Left - $pin.PreferredSize.Width - 12), 18)
    $miniBtn.Location = New-Object Drawing.Point(($pin.Left - $miniBtn.Width - 12), 12)
    $hideBtn.Location = New-Object Drawing.Point(($miniBtn.Left - $hideBtn.Width - 8), 12)
}

# 미니 막대: 진행 중·대기 건수만 그린다
$miniBar = New-Object Windows.Forms.Panel -Property @{ Dock = 'Fill'; BackColor = $T.bg; Visible = $false; Cursor = [Windows.Forms.Cursors]::SizeAll }
$expand = New-Object Windows.Forms.Button -Property @{
    Text = '펼치기'; Size = '64,28'; FlatStyle = 'Flat'; BackColor = $T.surface; ForeColor = $T.fg; Cursor = [Windows.Forms.Cursors]::Hand
}
$hideMini = New-Object Windows.Forms.Button -Property @{
    Text = '숨기기'; Size = '64,28'; FlatStyle = 'Flat'; BackColor = $T.surface; ForeColor = $T.fg; Cursor = [Windows.Forms.Cursors]::Hand
}
foreach ($b in $expand, $hideMini) { $b.FlatAppearance.BorderColor = $T.border; $b.FlatAppearance.MouseOverBackColor = $T.selected }
$miniBar.Controls.AddRange(@($expand, $hideMini))
$tips = New-Object Windows.Forms.ToolTip
$tips.SetToolTip($miniBar, '끌어서 옮기기 · 두 번 클릭하면 펼침')

$list = New-Object Windows.Forms.ListView -Property @{
    View = 'Details'; FullRowSelect = $true; Dock = 'Fill'; ShowItemToolTips = $true; OwnerDraw = $true
    BorderStyle = 'None'; BackColor = $T.surface; ForeColor = $T.fg; HeaderStyle = 'Nonclickable'; MultiSelect = $false
}
$rowHeight = New-Object Windows.Forms.ImageList -Property @{ ImageSize = '1,28' }   # 행 높이 확보용
$list.SmallImageList = $rowHeight
foreach ($c in @(('상태', 96), ('저장소', 170), ('내용', 300), ('브랜치', 150), ('시작', 56), ('걸린 시간', 90))) {
    [void]$list.Columns.Add($c[0], $c[1])
}
$form.Controls.AddRange(@($list, $head, $miniBar))

function Span([TimeSpan]$t) {
    if ($t.TotalHours -ge 1) { '{0}시간 {1}분' -f [int][Math]::Floor($t.TotalHours), $t.Minutes }
    elseif ($t.TotalMinutes -ge 1) { '{0}분 {1:00}초' -f $t.Minutes, $t.Seconds }
    else { '{0}초' -f [int]$t.TotalSeconds }
}

$script:summary = @{ all = 0; running = 0; queued = 0; failure = 0; done = 0 }
# 상태 필터: 머리의 칩을 누르면 그 상태만 보인다
$script:filter = 'all'
$script:lastRuns = @()
$script:chipRects = @()
$Filters = @(
    @{ key = 'all';     label = '전체';    empty = '표시할 CI가 없습니다.' }
    @{ key = 'running'; label = '실행 중'; empty = '지금 실행 중인 CI가 없습니다.' }
    @{ key = 'queued';  label = '대기';    empty = '대기 중인 CI가 없습니다.' }
    @{ key = 'failure'; label = '실패';    empty = '최근 실패한 CI가 없습니다.' }
    @{ key = 'done';    label = '완료';    empty = '최근 완료된 CI가 없습니다.' }
)
function Set-Filter($key) { $script:filter = $key; Render $script:lastRuns }
function Add-Row($kind, $cells, $tag) {
    $it = [Windows.Forms.ListViewItem]::new([string[]]$cells)
    $it.Tag = @{ kind = $kind } + $tag
    [void]$list.Items.Add($it)
    $it
}

function Render($runs) {
    $now = Get-Date
    $ok = @($runs | Where-Object { -not $_.error })
    $active = @($ok | Where-Object status -ne 'completed' | Sort-Object createdAt)
    $done = @($ok | Where-Object status -eq 'completed' | Sort-Object createdAt -Descending | Select-Object -First $DoneCount)
    $script:lastRuns = $runs
    $running = @($active | Where-Object status -eq 'in_progress')
    $queued = @($active | Where-Object status -ne 'in_progress')
    $failures = @($done | Where-Object { $State[$_.conclusion] -and $State[$_.conclusion][1] -eq 'failure' })
    $script:summary = @{
        all = $active.Count + $done.Count; running = $running.Count; queued = $queued.Count; failure = $failures.Count; done = $done.Count
    }
    # 필터별 구역: (제목, 실행들). '전체'만 진행 중/최근 완료 두 구역으로 나눈다
    $f = $Filters | Where-Object key -eq $script:filter
    $sections = New-Object Collections.ArrayList
    switch ($script:filter) {
        'running' { [void]$sections.Add(@('실행 중', $running)) }
        'queued'  { [void]$sections.Add(@('대기', $queued)) }
        'failure' { [void]$sections.Add(@('실패', $failures)) }
        'done'    { [void]$sections.Add(@('최근 완료', $done)) }
        default   { [void]$sections.Add(@('진행 중', $active)); [void]$sections.Add(@('최근 완료', $done)) }
    }
    $sel = if ($list.SelectedItems.Count) { $list.SelectedItems[0].Tag.url }
    $list.BeginUpdate(); $list.Items.Clear()
    foreach ($sec in $sections) {
        $rows = @($sec[1])
        [void](Add-Row 'section' @("$($sec[0]) · $($rows.Count)") @{})
        if (-not $rows.Count) {
            $msg = if ($script:filter -eq 'all' -and $sec[0] -eq '진행 중') { '지금 실행 중이거나 대기 중인 CI가 없습니다.' } else { $f.empty }
            [void](Add-Row 'empty' @($msg) @{})
            continue
        }
        foreach ($x in $rows) {
        $key = if ($x.status -eq 'completed') { $x.conclusion } else { $x.status }
        $st = if ($State[$key]) { $State[$key] } else { $key, 'neutral', $true }
        $start = [DateTimeOffset]::Parse($x.createdAt).LocalDateTime
        $end = if ($x.status -eq 'completed') { [DateTimeOffset]::Parse($x.updatedAt).LocalDateTime } else { $now }
        $title = if ($x.displayTitle) { $x.displayTitle } else { $x.name }
        $it = Add-Row 'run' @($st[0], $x.repo, $title, $x.headBranch, $start.ToString('HH:mm'), (Span ($end - $start))) @{ url = $x.url; tone = $st[1]; hollow = $st[2] }
        $it.ToolTipText = "$($x.name)`n$title`n$($x.headBranch)"
        if ($x.url -eq $sel) { $it.Selected = $true }
        }
    }
    $list.EndUpdate()
    # 항목이 늘어 세로 스크롤바가 생기면 폭이 줄어드는데 Resize가 안 와서 가로 스크롤바가 생겼다.
    # 스크롤바 배치가 끝난 뒤 칸 폭을 다시 맞추도록 메시지 큐 뒤로 미룬다
    if ($list.IsHandleCreated) { [void]$list.BeginInvoke([Action]{ Fit-Columns }) }
    $failed = @($runs | Where-Object error | ForEach-Object repo)
    $script:updated = $now
    $script:note = if ($failed) { "조회 실패: $($failed -join ', ')" } else { '' }
    $form.Text = "CI 현황 — 실행 중 $($script:summary.running) · 대기 $($script:summary.queued)"
    $head.Invalidate(); $miniBar.Invalidate(); Update-Strip
}

# --- 그리기 ---------------------------------------------------------------
$head.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
    [Windows.Forms.TextRenderer]::DrawText($g, 'CI 현황', $fontTitle, (New-Object Drawing.Point(12, 10)), $T.fg)
    $sub = if ($script:loading) { '불러오는 중…' }
           elseif ($script:updated) { "갱신 $($script:updated.ToString('HH:mm:ss')) · $([int]($RefreshSec / 60))분마다 자동" }
           else { '' }
    $tw = [Windows.Forms.TextRenderer]::MeasureText('CI 현황', $fontTitle).Width
    [Windows.Forms.TextRenderer]::DrawText($g, $sub, $fontBody, (New-Object Drawing.Point((12 + $tw + 6), 15)), $T.muted)
    # 필터 칩: 점 + 글자 + 건수. 누르면 그 상태만 보이고, 고른 칩은 밝은 테두리·배경으로 표시한다
    $x = 14
    $rects = @()
    foreach ($f in $Filters) {
        $n = $script:summary[$f.key]
        $text = "$($f.label) $n"
        $w = [Windows.Forms.TextRenderer]::MeasureText($text, $fontBold).Width + 26
        $rect = New-Object Drawing.Rectangle($x, 44, $w, 24)
        $on = $script:filter -eq $f.key
        $toneKey = @{ all = 'fg'; running = 'running'; queued = 'queued'; failure = 'failure'; done = 'success' }[$f.key]
        $tone = if ($n) { $T[$toneKey] } else { $T.muted }
        $b = New-Object Drawing.SolidBrush($(if ($on) { $T.selected } else { $T.surface })); $g.FillRectangle($b, $rect); $b.Dispose()
        $p = New-Object Drawing.Pen($(if ($on) { $T.fg } else { $T.border })); $g.DrawRectangle($p, $rect); $p.Dispose()
        $b = New-Object Drawing.SolidBrush($tone); $g.FillEllipse($b, ($x + 9), 52, 8, 8); $b.Dispose()
        [Windows.Forms.TextRenderer]::DrawText($g, $text, $fontBold, (New-Object Drawing.Rectangle(($x + 20), 44, ($w - 20), 24)), $(if ($n -or $on) { $T.fg } else { $T.muted }), $flags)
        $rects += @{ key = $f.key; rect = $rect }
        $x += $w + 6
    }
    $script:chipRects = $rects
    if ($script:note) {
        [Windows.Forms.TextRenderer]::DrawText($g, $script:note, $fontBody, (New-Object Drawing.Rectangle(($x + 6), 44, ($head.Width - $x - 20), 24)), $T.failure, $flags)
    }
})

$miniBar.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
    $p = New-Object Drawing.Pen($T.border); $g.DrawRectangle($p, 0, 0, ($miniBar.Width - 1), ($miniBar.Height - 1)); $p.Dispose()
    $h = $miniBar.Height
    [Windows.Forms.TextRenderer]::DrawText($g, 'CI', $fontTitle, (New-Object Drawing.Rectangle(12, 0, 36, $h)), $T.muted, $flags)
    $x = 50
    foreach ($chip in @(('running', '실행 중', $false), ('queued', '대기', $true))) {
        $n = $script:summary[$chip[0]]
        $tone = if ($n) { $T[$chip[0]] } else { $T.muted }
        $cy = [int](($h - 10) / 2)
        if ($chip[2]) { $p = New-Object Drawing.Pen($tone, 1.8); $g.DrawEllipse($p, $x, $cy, 10, 10); $p.Dispose() }
        else { $b = New-Object Drawing.SolidBrush($tone); $g.FillEllipse($b, $x, $cy, 10, 10); $b.Dispose() }
        $text = "$($chip[1]) $n"
        [Windows.Forms.TextRenderer]::DrawText($g, $text, $fontBold, (New-Object Drawing.Rectangle(($x + 16), 0, 120, $h)), $(if ($n) { $T.fg } else { $T.muted }), $flags)
        $x += 16 + [Windows.Forms.TextRenderer]::MeasureText($text, $fontBold).Width + 18
    }
})

$list.Add_DrawColumnHeader({
    param($s, $e)
    $b = New-Object Drawing.SolidBrush($T.bg); $e.Graphics.FillRectangle($b, $e.Bounds); $b.Dispose()
    $p = New-Object Drawing.Pen($T.border); $e.Graphics.DrawLine($p, $e.Bounds.Left, ($e.Bounds.Bottom - 1), $e.Bounds.Right, ($e.Bounds.Bottom - 1)); $p.Dispose()
    $r = New-Object Drawing.Rectangle(($e.Bounds.X + 10), $e.Bounds.Y, ($e.Bounds.Width - 14), $e.Bounds.Height)
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $fontSection, $r, $T.muted, $flags)
})

# 행 전체를 DrawItem 한 곳에서 그린다. 마우스를 올리면(핫 트래킹) WinForms가 DrawItem만 다시 부르고
# DrawSubItem은 부르지 않아서, 칸 글자를 DrawSubItem에서 그리면 배경만 덮이고 글자가 사라졌다.
$list.Add_DrawItem({
    param($s, $e)
    $tag = $e.Item.Tag
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
    $bgc = if ($e.Item.Selected -and $tag.kind -eq 'run') { $T.selected } else { $T.surface }
    $b = New-Object Drawing.SolidBrush($bgc); $g.FillRectangle($b, $e.Bounds); $b.Dispose()
    if ($tag.kind -eq 'section') {
        $r = New-Object Drawing.Rectangle(($e.Bounds.X + 10), ($e.Bounds.Y + 6), ($e.Bounds.Width - 20), ($e.Bounds.Height - 6))
        [Windows.Forms.TextRenderer]::DrawText($g, $e.Item.Text, $fontSection, $r, $T.muted, $flags)
        return
    }
    if ($tag.kind -eq 'empty') {
        $r = New-Object Drawing.Rectangle(($e.Bounds.X + 30), $e.Bounds.Y, ($e.Bounds.Width - 40), $e.Bounds.Height)
        [Windows.Forms.TextRenderer]::DrawText($g, $e.Item.Text, $fontBody, $r, $T.muted, $flags)
        return
    }
    $x = $e.Bounds.X
    for ($i = 0; $i -lt $list.Columns.Count; $i++) {
        $cw = $list.Columns[$i].Width
        $text = $e.Item.SubItems[$i].Text
        if ($i -eq 0) {
            $tone = $T[$tag.tone]
            $cy = $e.Bounds.Y + [int](($e.Bounds.Height - 8) / 2)
            if ($tag.hollow) { $pen = New-Object Drawing.Pen($tone, 1.6); $g.DrawEllipse($pen, ($x + 12), $cy, 8, 8); $pen.Dispose() }
            else { $b = New-Object Drawing.SolidBrush($tone); $g.FillEllipse($b, ($x + 12), $cy, 8, 8); $b.Dispose() }
            $r = New-Object Drawing.Rectangle(($x + 26), $e.Bounds.Y, ($cw - 28), $e.Bounds.Height)
            [Windows.Forms.TextRenderer]::DrawText($g, $text, $fontBold, $r, $tone, $flags)
        } else {
            $font = if ($i -ge 4) { $fontNum } else { $fontBody }
            $color = if ($i -in 1, 2) { $T.fg } else { $T.muted }
            $r = New-Object Drawing.Rectangle(($x + 10), $e.Bounds.Y, ($cw - 14), $e.Bounds.Height)
            [Windows.Forms.TextRenderer]::DrawText($g, $text, $font, $r, $color, $flags)
        }
        $x += $cw
    }
})
# DrawItem이 이미 다 그렸으므로 칸 단위 그리기는 하지 않는다(OwnerDraw라 처리기는 있어야 기본 그리기가 안 끼어든다)
$list.Add_DrawSubItem({ param($s, $e) })

# --- 작업표시줄 막대 --------------------------------------------------------
# kindsusu/codex-usage-widget의 작업표시줄 막대와 같은 방식: 계층(layered) 창을 WS_CHILD로 바꿔 작업표시줄(Shell_TrayWnd) 안에 붙이고
# 직접 그린 비트맵을 UpdateLayeredWindow로 올린다. Windows 11 작업표시줄은 XAML 합성 층이 덮어서 보통 자식 창은 안 보인다.
# 그 위젯 막대는 작업표시줄 왼쪽을 쓰므로, 이 막대는 알림 영역(TrayNotifyWnd) 바로 왼쪽에 둔다.
# 순서가 중요하다: 처음부터 계층·숨김 상태로 만든다 → 자식으로 붙인다 → 그린다 → 보인다.
# WinForms 폼을 먼저 띄워 놓고 바꾸는 방식은 UpdateLayeredWindow가 성공해도 화면에 나타나지 않았다(2026-10-28 실측).
# 기본 자리는 알림 영역 바로 왼쪽. 막대를 좌우로 끌어 옮기면 그 자리(작업표시줄 안 x)를 기억한다.
# 놓을 때 사용량 위젯 막대와 겹치면 가까운 옆으로 비켜 선다.
# ponytail: 작업표시줄 앱 아이콘은 피하지 않는다(UIA 탐색 없음). 아이콘 위에 놓으면 겹친다.
# ponytail: 막대 크기·글꼴은 100% 배율(96 DPI) 기준이다. 배율을 올리면 막대가 작게 보인다.
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
public class CiStripWindow : NativeWindow {
    [StructLayout(LayoutKind.Sequential)] struct PT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct RC { public int L, T, R, B; }
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] static extern IntPtr SetCapture(IntPtr h);
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern bool GetCursorPos(out PT p);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RC r);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
    [DllImport("user32.dll")] static extern IntPtr LoadCursor(IntPtr inst, int id);
    [DllImport("user32.dll")] static extern IntPtr SetCursor(IntPtr c);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);

    public event EventHandler LeftClick, RightClick, Dropped;
    public int MinX, MaxX, Y;          // 끌 수 있는 범위(작업표시줄 안 좌표)
    public int DroppedX, DropScreenX, DropScreenY, GrabOffset;   // 놓은 자리(작업표시줄 안 x), 놓을 때 커서(화면), 막대 왼쪽에서 잡은 위치
    bool pressed, dragging;
    int startCursor, startX;

    public CiStripWindow() {
        var cp = new CreateParams();
        cp.Caption = "CI status strip";
        cp.Style = unchecked((int)0x80000000);                 // WS_POPUP, 아직 숨김
        cp.ExStyle = 0x00080000 | 0x08000000 | 0x00000080;     // WS_EX_LAYERED | NOACTIVATE | TOOLWINDOW
        cp.Width = 1; cp.Height = 1;
        IntPtr old = SetThreadDpiAwarenessContext(new IntPtr(-4));   // 작업표시줄과 같은 실제 픽셀 좌표계
        try { CreateHandle(cp); } finally { SetThreadDpiAwarenessContext(old); }
    }

    int CurrentX() {
        RC me, parent; GetWindowRect(Handle, out me); GetWindowRect(GetParent(Handle), out parent);
        return me.L - parent.L;
    }

    // 작업표시줄에 붙은 사용량 위젯 막대(codex/claude-usage-widget)의 가로 구간. [왼쪽, 오른쪽, 왼쪽, 오른쪽, ...]
    public static int[] SiblingSpans(IntPtr taskbar, IntPtr self) {
        var spans = new List<int>();
        RC tb; GetWindowRect(taskbar, out tb);
        EnumChildWindows(taskbar, (h, l) => {
            if (h == self || GetParent(h) != taskbar) return true;
            var sb = new StringBuilder(256); GetClassName(h, sb, 256);
            string c = sb.ToString();
            if (c.StartsWith("CodexUsageTaskbar") || c.StartsWith("ClaudeUsageTaskbarSurface")) {
                RC r; GetWindowRect(h, out r); spans.Add(r.L - tb.L); spans.Add(r.R - tb.L);
            }
            return true;
        }, IntPtr.Zero);
        return spans.ToArray();
    }

    void Drop() {
        PT c; GetCursorPos(out c);
        DroppedX = CurrentX(); DropScreenX = c.X; DropScreenY = c.Y;
        if (Dropped != null) Dropped(this, EventArgs.Empty);
    }

    protected override void WndProc(ref Message m) {
        switch (m.Msg) {
            case 0x0021: m.Result = new IntPtr(3); return;     // WM_MOUSEACTIVATE → MA_NOACTIVATE
            case 0x0020:                                        // WM_SETCURSOR: 평소 손, 끄는 중 좌우 화살표
                SetCursor(LoadCursor(IntPtr.Zero, dragging ? 32644 : 32649)); m.Result = new IntPtr(1); return;
            case 0x0201: {                                      // WM_LBUTTONDOWN: 누른 자리 기억
                PT c; GetCursorPos(out c);
                pressed = true; dragging = false; startCursor = c.X; startX = CurrentX();
                RC me; GetWindowRect(Handle, out me); GrabOffset = c.X - me.L;
                SetCapture(Handle);
                return;
            }
            case 0x0200:                                        // WM_MOUSEMOVE: 4px 넘게 움직이면 끌기
                if (pressed) {
                    PT c; GetCursorPos(out c);
                    int dx = c.X - startCursor;
                    if (!dragging && Math.Abs(dx) >= 4) dragging = true;
                    if (dragging) {
                        int nx = Math.Max(MinX, Math.Min(MaxX, startX + dx));
                        SetWindowPos(Handle, IntPtr.Zero, nx, Y, 0, 0, 0x0001 | 0x0004 | 0x0010);   // NOSIZE|NOZORDER|NOACTIVATE
                        SetCursor(LoadCursor(IntPtr.Zero, 32644));
                    }
                }
                break;
            case 0x0202:                                        // WM_LBUTTONUP: 끌었으면 놓기, 아니면 클릭
                if (pressed) {
                    pressed = false; bool wasDrag = dragging; dragging = false;
                    ReleaseCapture();
                    if (wasDrag) { Drop(); }
                    else if (LeftClick != null) LeftClick(this, EventArgs.Empty);
                }
                return;
            case 0x0215:                                        // WM_CAPTURECHANGED: 끌다가 포커스를 잃으면 그 자리에 놓는다
                if (pressed) {
                    pressed = false; bool wasDrag = dragging; dragging = false;
                    if (wasDrag) Drop();
                }
                break;
            case 0x0205:                                        // WM_RBUTTONUP
                if (RightClick != null) RightClick(this, EventArgs.Empty);
                break;
        }
        base.WndProc(ref m);
    }
}
"@
$StripW = 118; $StripH = 40
$stripPosFile = Join-Path $env:LOCALAPPDATA 'ci-widget.strip'   # 옮긴 막대 자리 "화면장치|x"(x는 작업표시줄 안 좌표, 비면 기본 자리)
$script:stripDevice = $null
# 작업표시줄 목록: 주(Shell_TrayWnd)와 다른 화면의 보조(Shell_SecondaryTrayWnd). 화면 장치 이름으로 구분한다
function Get-Taskbars {
    $N = [CiWidget.Native]
    foreach ($cls in 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd') {
        $h = [IntPtr]::Zero
        while (($h = $N::FindWindowEx([IntPtr]::Zero, $h, $cls, $null)) -ne [IntPtr]::Zero) {
            $r = New-Object CiWidget.Native+RECT; [void]$N::GetWindowRect($h, [ref]$r)
            [pscustomobject]@{ Handle = $h; Rect = $r; Primary = ($cls -eq 'Shell_TrayWnd'); Device = [Windows.Forms.Screen]::FromHandle($h).DeviceName }
        }
    }
}
function Read-StripPos {
    $pos = @{ Device = $null; X = $null }
    if (-not (Test-Path $stripPosFile)) { return $pos }
    $parts = (Get-Content $stripPosFile -Raw).Trim() -split '\|'
    $v = 0
    if ($parts.Count -ge 2) { $pos.Device = $parts[0]; if ([int]::TryParse($parts[1], [ref]$v)) { $pos.X = $v } }
    elseif ([int]::TryParse($parts[0], [ref]$v)) { $pos.X = $v }   # 예전 형식(x만): 주 작업표시줄
    $pos
}
function Save-StripPos($device, $x) { try { [IO.File]::WriteAllText($stripPosFile, "$device|$x") } catch {} }
$script:stripParent = [IntPtr]::Zero
$script:stripBack = $T.bg
$stripMenu = New-Object Windows.Forms.ContextMenuStrip
[void]$stripMenu.Items.Add('창 열기/숨기기', $null, { Toggle-Main })
[void]$stripMenu.Items.Add('새로고침', $null, { $script:tick = 0; Start-Fetch })
$moveMenu = New-Object Windows.Forms.ToolStripMenuItem('작업표시줄 옮기기')
[void]$moveMenu.DropDownItems.Add('…')   # 열 때 채운다(빈 하위 메뉴는 화살표가 안 보인다)
$moveMenu.add_DropDownOpening({
    $moveMenu.DropDownItems.Clear()
    foreach ($bar in @(Get-Taskbars)) {
        $label = "$(if ($bar.Primary) { '주 화면' } else { '보조 화면' }) ($($bar.Device -replace '^\\\\\.\\', ''))"
        $item = $moveMenu.DropDownItems.Add($label)
        $item.Tag = $bar.Device
        $item.Checked = ($bar.Device -eq $script:stripDevice)
        $item.add_Click({ param($s, $e) Save-StripPos $s.Tag ''; [void]$form.BeginInvoke([Action]{ Attach-Strip }) })
    }
})
[void]$stripMenu.Items.Add($moveMenu)
[void]$stripMenu.Items.Add('막대 위치 초기화', $null, { Remove-Item $stripPosFile -ErrorAction SilentlyContinue; [void]$form.BeginInvoke([Action]{ Attach-Strip }) })
[void]$stripMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$stripMenu.Items.Add('종료', $null, { Exit-App })
function New-StripWindow {
    $w = New-Object CiStripWindow
    $w.add_LeftClick({ Toggle-Main })
    $w.add_Dropped({
        # 커서를 다른 화면에 놓았으면 그 화면의 작업표시줄로 옮긴다(작업표시줄 위가 아니어도 그 화면이면 된다)
        $pt = New-Object Drawing.Point($script:sw.DropScreenX, $script:sw.DropScreenY)
        $dev = [Windows.Forms.Screen]::FromPoint($pt).DeviceName
        $target = @(Get-Taskbars) | Where-Object Device -eq $dev | Select-Object -First 1
        if ($target -and $target.Handle -ne $script:stripParent) { Save-StripPos $dev ($pt.X - $target.Rect.Left - $script:sw.GrabOffset) }
        else { Save-StripPos $script:stripDevice $script:sw.DroppedX }
        # 막대 창의 메시지 처리 도중에 그 창을 지우면 안 되므로 메시지 큐 뒤로 미룬다
        [void]$form.BeginInvoke([Action]{ Attach-Strip })
    })
    $w.add_RightClick({
        $stripMenu.Show([Windows.Forms.Cursor]::Position)
        # 활성화하지 않는 창에서 띄운 메뉴는 바깥을 눌러도 안 닫힌다. 메뉴를 전경으로 올린다
        [void][CiWidget.Native]::SetForegroundWindow($stripMenu.Handle)
    })
    $w
}
$script:sw = $null

# 바탕은 거의 투명(알파 1)해서 작업표시줄이 비쳐 보이고, 클릭은 그대로 받는다.
# 글자는 GDI+로 그린다. GDI(TextRenderer)는 32비트 비트맵의 알파를 0으로 지워 글자가 뚫린다.
function Draw-Strip([Drawing.Graphics]$g, [int]$w, [int]$h) {
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([Drawing.Color]::FromArgb(1, 0, 0, 0))
    # 작업표시줄이 밝은 테마면 글자·점 색을 어둡게 바꿔 대비를 지킨다
    $light = $script:stripBack.GetBrightness() -gt 0.5
    $fg = if ($light) { C '#0F172A' } else { $T.fg }
    $dim = if ($light) { C '#475569' } else { $T.muted }
    # 작업표시줄 막대에서는 실행 중을 초록으로 보여 준다(사용자 요청). 밝은 작업표시줄은 대비를 위해 진한 초록
    $tones = if ($light) { @{ running = C '#15803D'; queued = C '#B45309' } } else { @{ running = $T.success; queued = $T.queued } }
    $sf = New-Object Drawing.StringFormat -Property @{ LineAlignment = 'Center'; FormatFlags = 'NoWrap' }
    $b = New-Object Drawing.SolidBrush($dim); $g.DrawString('CI', $fontStripTitle, $b, (New-Object Drawing.RectangleF(2, 0, 30, $h)), $sf); $b.Dispose()
    $y = [int](($h - 36) / 2)
    foreach ($chip in @(('running', '실행 중', $false), ('queued', '대기', $true))) {
        $n = $script:summary[$chip[0]]
        $tone = if ($n) { $tones[$chip[0]] } else { $dim }
        if ($chip[2]) { $pen = New-Object Drawing.Pen($tone, 1.6); $g.DrawEllipse($pen, 33, ($y + 5), 8, 8); $pen.Dispose() }
        else { $b = New-Object Drawing.SolidBrush($tone); $g.FillEllipse($b, 33, ($y + 5), 8, 8); $b.Dispose() }
        $b = New-Object Drawing.SolidBrush($(if ($n) { $fg } else { $dim }))
        $g.DrawString("$($chip[1]) $n", $fontStrip, $b, (New-Object Drawing.RectangleF(45, $y, ($w - 46), 18)), $sf); $b.Dispose()
        $y += 18
    }
    $sf.Dispose()
}
function Update-Strip {
    if (-not $script:sw -or $script:stripParent -eq [IntPtr]::Zero) { return }
    $N = [CiWidget.Native]
    $w = $StripW; $h = $StripH
    $bmp = New-Object Drawing.Bitmap($w, $h, [Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $g = [Drawing.Graphics]::FromImage($bmp); Draw-Strip $g $w $h; $g.Dispose()
    $screen = $N::GetDC([IntPtr]::Zero); $mem = $N::CreateCompatibleDC($screen)
    # GDI+ GetHbitmap은 알파를 잃는다. 미리 곱한(PArgb) 픽셀을 32비트 DIB에 그대로 옮긴다
    $bi = New-Object CiWidget.Native+BITMAPINFOHEADER -Property @{ biSize = 40; biWidth = $w; biHeight = -$h; biPlanes = 1; biBitCount = 32 }
    $bits = [IntPtr]::Zero
    $hbmp = $N::CreateDIBSection($mem, [ref]$bi, 0, [ref]$bits, [IntPtr]::Zero, 0)
    $data = $bmp.LockBits((New-Object Drawing.Rectangle(0, 0, $w, $h)), 'ReadOnly', [Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $buf = New-Object byte[] ($w * $h * 4)
    [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
    [Runtime.InteropServices.Marshal]::Copy($buf, 0, $bits, $buf.Length)
    $bmp.UnlockBits($data)
    $old = $N::SelectObject($mem, $hbmp)
    $size = New-Object CiWidget.Native+SIZE -Property @{ cx = $w; cy = $h }
    $src = New-Object CiWidget.Native+POINT
    $blend = New-Object CiWidget.Native+BLENDFUNCTION -Property @{ SourceConstantAlpha = 255; AlphaFormat = 1 }   # AC_SRC_ALPHA
    [void]$N::UpdateLayeredWindow($script:sw.Handle, $screen, [IntPtr]::Zero, [ref]$size, $mem, [ref]$src, 0, [ref]$blend, 2)   # ULW_ALPHA
    [void]$N::SelectObject($mem, $old); [void]$N::DeleteObject($hbmp); [void]$N::DeleteDC($mem); [void]$N::ReleaseDC([IntPtr]::Zero, $screen)
    $bmp.Dispose()
}

# 사용량 위젯 막대([왼쪽, 오른쪽, ...])와 겹치면, 아무것과도 안 겹치는 자리 중 놓은 곳에서 가장 가까운 곳으로 비킨다
function Resolve-StripX([int]$x, [int[]]$spans, [int]$minX, [int]$maxX) {
    $x = [Math]::Max($minX, [Math]::Min($maxX, $x))
    $cands = @($x, $minX, $maxX)
    for ($i = 0; $i + 1 -lt $spans.Count; $i += 2) { $cands += $spans[$i] - $StripW - 4; $cands += $spans[$i + 1] + 4 }
    $best = $null
    foreach ($c in $cands) {
        if ($c -lt $minX -or $c -gt $maxX) { continue }
        $hit = $false
        for ($i = 0; $i + 1 -lt $spans.Count; $i += 2) { if ($c -lt $spans[$i + 1] -and ($c + $StripW) -gt $spans[$i]) { $hit = $true; break } }
        if (-not $hit -and ($null -eq $best -or [Math]::Abs($c - $x) -lt [Math]::Abs($best - $x))) { $best = $c }
    }
    if ($null -eq $best) { $x } else { $best }
}

function Attach-Strip {
    $N = [CiWidget.Native]
    $bars = @(Get-Taskbars)
    $pos = Read-StripPos
    $bar = $bars | Where-Object { $pos.Device -and $_.Device -eq $pos.Device } | Select-Object -First 1
    # 저장한 화면이 없으면(모니터를 뺐을 때 등) 저장값은 그대로 두고 주 작업표시줄에 둔다
    $useSaved = [bool]$bar -or (-not $pos.Device)
    if (-not $bar) { $bar = $bars | Where-Object Primary | Select-Object -First 1 }
    if (-not $bar) { return }
    $tb = $bar.Handle; $rb = $bar.Rect
    $script:stripDevice = $bar.Device
    $right = $rb.Right - 100   # 보조 작업표시줄은 알림 영역 창이 없고 오른쪽 끝에 시계만 있다
    $tray = $N::FindWindowEx($tb, [IntPtr]::Zero, 'TrayNotifyWnd', $null)
    if ($tray -ne [IntPtr]::Zero) { $rt = New-Object CiWidget.Native+RECT; [void]$N::GetWindowRect($tray, [ref]$rt); $right = $rt.Left }
    $minX = 4; $maxX = $right - $rb.Left - $StripW - 8
    $x = if ($useSaved -and $null -ne $pos.X) { $pos.X } else { $maxX }
    $x = [Math]::Max($minX, [Math]::Min($maxX, $x))
    $self = if ($script:sw) { $script:sw.Handle } else { [IntPtr]::Zero }
    $x = Resolve-StripX $x ([CiStripWindow]::SiblingSpans($tb, $self)) $minX $maxX
    $y = [int](($rb.Bottom - $rb.Top - $StripH) / 2)
    # 바탕색은 막대 바로 왼쪽 작업표시줄 한 점을 읽어 정한다(밝은/어두운 작업표시줄에 맞춰 글자색을 고르려고)
    try {
        $px = New-Object Drawing.Bitmap(1, 1)
        $pg = [Drawing.Graphics]::FromImage($px)
        $pg.CopyFromScreen(($rb.Left + $x - 4), ($rb.Top + 4), 0, 0, (New-Object Drawing.Size(1, 1)))
        $script:stripBack = $px.GetPixel(0, 0); $pg.Dispose(); $px.Dispose()
    } catch {}
    # 처음이거나 탐색기가 다시 시작돼 작업표시줄이 바뀌었으면(그때 막대 창도 함께 사라진다) 새로 만들어 붙인다
    if (-not $script:sw -or $script:sw.Handle -eq [IntPtr]::Zero -or $N::GetParent($script:sw.Handle) -ne $tb) {
        if ($script:sw -and $script:sw.Handle -ne [IntPtr]::Zero) { $script:sw.DestroyHandle() }
        $script:sw = New-StripWindow
        $h = $script:sw.Handle
        $script:sw.MinX = $minX; $script:sw.MaxX = $maxX; $script:sw.Y = $y
        $style = $N::GetWindowLongPtr($h, -16).ToInt64()
        $style = ($style -band -bnot 0x80000000L) -bor 0x40000000L -bor 0x04000000L   # WS_POPUP 빼고 WS_CHILD|WS_CLIPSIBLINGS
        [void]$N::SetWindowLongPtr($h, -16, [IntPtr]$style)
        [void]$N::SetParent($h, $tb)
        $script:stripParent = $tb
        [void]$N::SetWindowPos($h, [IntPtr]::Zero, $x, $y, $StripW, $StripH, 0x0010 -bor 0x0020)   # NOACTIVATE|FRAMECHANGED
        Update-Strip
        [void]$N::ShowWindow($h, 4)   # SW_SHOWNOACTIVATE
        return
    }
    $script:sw.MinX = $minX; $script:sw.MaxX = $maxX; $script:sw.Y = $y
    [void]$N::SetWindowPos($script:sw.Handle, [IntPtr]::Zero, $x, $y, $StripW, $StripH, 0x0010 -bor 0x0004)   # NOACTIVATE|NOZORDER
    Update-Strip
}

# --- 동작 -----------------------------------------------------------------
$script:job = $null; $script:handle = $null; $script:updated = $null; $script:note = ''; $script:tick = 0; $script:loading = $false
function Start-Fetch {
    if ($script:job) { return }
    $script:job = [powershell]::Create().AddScript($fetch).AddArgument($Org).AddArgument($Repos)
    $script:handle = $script:job.BeginInvoke()
    $script:loading = $true; $btn.Enabled = $false; $btn.Text = '불러오는 중'; $head.Invalidate()
}
function Finish-Fetch {
    if (-not $script:job -or -not $script:handle.IsCompleted) { return $false }
    try { Render @($script:job.EndInvoke($script:handle)) }
    catch { $script:note = "오류: $($_.Exception.Message)" }
    $script:job.Dispose(); $script:job = $null
    $script:loading = $false; $btn.Enabled = $true; $btn.Text = '새로고침'; $head.Invalidate()
    return $true
}
$script:fullSize = $form.Size
function Set-Mini([bool]$on) {
    $r = $form.Bounds
    if ($on) {
        $script:fullSize = $form.Size
        $head.Visible = $false; $list.Visible = $false; $miniBar.Visible = $true
        $form.FormBorderStyle = 'None'; $form.MinimumSize = '0,0'; $form.Size = '400,48'
    } else {
        $miniBar.Visible = $false; $head.Visible = $true; $list.Visible = $true
        $form.FormBorderStyle = 'Sizable'; $form.Size = $script:fullSize; $form.MinimumSize = '720,260'
    }
    # 오른쪽 아래 모서리를 기준으로 제자리에서 접고 펼친다(화면 밖으로 나가지 않게)
    $wa = [Windows.Forms.Screen]::FromRectangle($r).WorkingArea
    $x = [Math]::Max($wa.Left, [Math]::Min($r.Right - $form.Width, $wa.Right - $form.Width))
    $y = [Math]::Max($wa.Top, [Math]::Min($r.Bottom - $form.Height, $wa.Bottom - $form.Height))
    $form.Location = New-Object Drawing.Point($x, $y)
    $expand.Location = New-Object Drawing.Point(($miniBar.Width - $expand.Width - 10), [int](($miniBar.Height - $expand.Height) / 2))
    $hideMini.Location = New-Object Drawing.Point(($expand.Left - $hideMini.Width - 6), $expand.Top)
    if (-not $Snapshot) { try { [IO.File]::WriteAllText($modeFile, $(if ($on) { 'mini' } else { 'full' })) } catch {} }
}
# 숨기기: 창만 감추고 작업표시줄 막대는 남긴다. 숨긴 상태는 기억해서 다음 실행 때도 숨긴 채로 시작한다
function Hide-Main {
    $form.Hide()
    try { [IO.File]::WriteAllText($hiddenFile, '') } catch {}
}
function Show-Main {
    $form.Show(); $form.WindowState = 'Normal'; $form.Activate()
    Remove-Item $hiddenFile -ErrorAction SilentlyContinue
}
function Toggle-Main { if ($form.Visible -and $form.WindowState -ne 'Minimized') { Hide-Main } else { Show-Main } }
function Exit-App { $script:exiting = $true; $timer.Stop(); if ($script:sw) { $script:sw.DestroyHandle() }; $form.Close(); [Windows.Forms.Application]::Exit() }
# 창의 X는 작업표시줄 막대로 숨기기만 한다(종료는 막대 오른쪽 클릭 메뉴)
$form.Add_FormClosing({ param($s, $e) if (-not $script:exiting -and $e.CloseReason -eq 'UserClosing') { $e.Cancel = $true; Hide-Main } })
function Open-Selected {
    if ($list.SelectedItems.Count -and $list.SelectedItems[0].Tag.url) { Start-Process $list.SelectedItems[0].Tag.url }
}

$btn.Add_Click({ $script:tick = 0; Start-Fetch })
$pin.Add_CheckedChanged({ $form.TopMost = $pin.Checked })
$list.Add_DoubleClick({ Open-Selected })
$list.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { Open-Selected } })
# 구분 행·빈 행은 선택되지 않게 한다
$list.Add_ItemSelectionChanged({ param($s, $e) if ($e.IsSelected -and $e.Item.Tag.kind -ne 'run') { $e.Item.Selected = $false } })
$miniBtn.Add_Click({ Set-Mini $true })
$hideBtn.Add_Click({ Hide-Main })
$hideMini.Add_Click({ Hide-Main })
$expand.Add_Click({ Set-Mini $false })
# 미니 막대는 아무 데나 끌어서 옮기고, 두 번 클릭하면 펼친다
$miniBar.Add_MouseDown({
    param($s, $e)
    if ($e.Button -ne 'Left') { return }
    if ($e.Clicks -ge 2) { Set-Mini $false; return }
    [void][CiWidget.Native]::ReleaseCapture()
    [void][CiWidget.Native]::SendMessage($form.Handle, 0xA1, [IntPtr]2, [IntPtr]::Zero)   # WM_NCLBUTTONDOWN, HTCAPTION
})
$head.Add_Resize({ Place-Head; $head.Invalidate() })
$head.Add_MouseClick({
    param($s, $e)
    $hit = $script:chipRects | Where-Object { $_.rect.Contains($e.Location) } | Select-Object -First 1
    if ($hit) { Set-Filter $hit.key }
})
$head.Add_MouseMove({
    param($s, $e)
    $over = [bool]($script:chipRects | Where-Object { $_.rect.Contains($e.Location) })
    $head.Cursor = if ($over) { [Windows.Forms.Cursors]::Hand } else { [Windows.Forms.Cursors]::Default }
})
# '내용' 칸이 남는 폭을 채워 머리글 오른쪽에 빈 칸(흰 띠)이 생기지 않게 한다
function Fit-Columns {
    $other = 0; foreach ($i in 0, 1, 3, 4, 5) { $other += $list.Columns[$i].Width }
    $list.Columns[2].Width = [Math]::Max(160, $list.ClientSize.Width - $other - 1)
}
$list.Add_Resize({ Fit-Columns })
# 테두리 방식을 바꾸면 창 핸들이 다시 만들어질 수 있어 그때마다 어두운 제목 표시줄을 다시 건다
$form.Add_HandleCreated({
    $v = 1
    try { [void][CiWidget.Native]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4) } catch {}
})
$form.Add_Load({
    try { [void][CiWidget.Native]::SetWindowTheme($list.Handle, 'DarkMode_Explorer', $null) } catch {}
    Fit-Columns
})
$startMini = $Mini -or (-not $Snapshot -and (Test-Path $modeFile) -and (Get-Content $modeFile -Raw) -match 'mini')
Place-Head

if ($Snapshot) {
    Start-Fetch
    while (-not (Finish-Fetch)) { Start-Sleep -Milliseconds 200 }
    $form.Show(); if ($startMini) { Set-Mini $true }; 1..5 | ForEach-Object { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp.Save($Snapshot)
    # 작업표시줄 막대는 붙이지 않고 그림만 따로 저장한다(<이름>-strip.png)
    $sb = New-Object Drawing.Bitmap($StripW, $StripH)
    $sg = [Drawing.Graphics]::FromImage($sb); $sg.Clear($script:stripBack); Draw-Strip $sg $StripW $StripH; $sg.Dispose()
    $sb.Save(($Snapshot -replace '\.png$', '-strip.png'))
    $script:exiting = $true; $form.Close(); exit
}

$script:exiting = $false; $script:stripTick = 0
$timer = New-Object Windows.Forms.Timer -Property @{ Interval = 1000 }
$timer.Add_Tick({
    [void](Finish-Fetch)
    if (++$script:tick -ge $RefreshSec) { $script:tick = 0; Start-Fetch }
    # 탐색기 재시작·해상도 변경에 대비해 10초마다 자리를 다시 맞춘다(창 찾기·위치 지정뿐이라 가볍다)
    if (++$script:stripTick -ge 10) { $script:stripTick = 0; try { Attach-Strip } catch { $script:note = "작업표시줄: $($_.Exception.Message)"; $_ | Out-File (Join-Path $env:TEMP 'ci-widget-strip.err') } }
    if ($showSignal.WaitOne(0)) { Show-Main }
})
# 처음 보일 때(숨긴 채 시작했으면 처음 열 때) 지난 모드를 적용한다
$form.Add_Shown({ if ($startMini) { Set-Mini $true } })
[void]$form.Handle   # 숨긴 채 시작해도 $form.BeginInvoke를 쓸 수 있게 창 핸들을 먼저 만든다
try { Attach-Strip } catch { $script:note = "작업표시줄: $($_.Exception.Message)"; $_ | Out-File (Join-Path $env:TEMP 'ci-widget-strip.err') }
Start-Fetch; $timer.Start()
# 창을 숨겨도 계속 돌도록 창 없는 메시지 루프로 돌린다(종료는 Exit-App)
if (-not (Test-Path $hiddenFile)) { $form.Show() }
[Windows.Forms.Application]::Run((New-Object Windows.Forms.ApplicationContext))
