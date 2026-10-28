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
if (-not $Snapshot -and -not $mutex.WaitOne(0)) { exit }

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
    Text = 'CI 현황'; TopMost = $true; Font = $fontBody; Size = '900,500'; MinimumSize = '560,260'
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
foreach ($b in $btn, $miniBtn) { $b.FlatAppearance.BorderColor = $T.border; $b.FlatAppearance.MouseOverBackColor = $T.selected }
$head.Controls.AddRange(@($btn, $pin, $miniBtn))
function Place-Head {
    $btn.Location = New-Object Drawing.Point(($head.Width - $btn.Width - 14), 12)
    $pin.Location = New-Object Drawing.Point(($btn.Left - $pin.PreferredSize.Width - 12), 18)
    $miniBtn.Location = New-Object Drawing.Point(($pin.Left - $miniBtn.Width - 12), 12)
}

# 미니 막대: 진행 중·대기 건수만 그린다
$miniBar = New-Object Windows.Forms.Panel -Property @{ Dock = 'Fill'; BackColor = $T.bg; Visible = $false; Cursor = [Windows.Forms.Cursors]::SizeAll }
$expand = New-Object Windows.Forms.Button -Property @{
    Text = '펼치기'; Size = '64,28'; FlatStyle = 'Flat'; BackColor = $T.surface; ForeColor = $T.fg; Cursor = [Windows.Forms.Cursors]::Hand
}
$expand.FlatAppearance.BorderColor = $T.border
$expand.FlatAppearance.MouseOverBackColor = $T.selected
$miniBar.Controls.Add($expand)
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

$script:summary = @{ running = 0; queued = 0; failure = 0 }
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
    $script:summary = @{
        running = @($active | Where-Object status -eq 'in_progress').Count
        queued = @($active | Where-Object status -ne 'in_progress').Count
        failure = @($done | Where-Object { $State[$_.conclusion] -and $State[$_.conclusion][1] -eq 'failure' }).Count
    }
    $sel = if ($list.SelectedItems.Count) { $list.SelectedItems[0].Tag.url }
    $list.BeginUpdate(); $list.Items.Clear()
    [void](Add-Row 'section' @("진행 중 · $($active.Count)") @{})
    if (-not $active.Count) { [void](Add-Row 'empty' @('지금 실행 중이거나 대기 중인 CI가 없습니다.') @{}) }
    $first = $true
    foreach ($x in $active + $done) {
        if ($x.status -eq 'completed' -and $first) { $first = $false; [void](Add-Row 'section' @("최근 완료 · $($done.Count)") @{}) }
        $key = if ($x.status -eq 'completed') { $x.conclusion } else { $x.status }
        $st = if ($State[$key]) { $State[$key] } else { $key, 'neutral', $true }
        $start = [DateTimeOffset]::Parse($x.createdAt).LocalDateTime
        $end = if ($x.status -eq 'completed') { [DateTimeOffset]::Parse($x.updatedAt).LocalDateTime } else { $now }
        $title = if ($x.displayTitle) { $x.displayTitle } else { $x.name }
        $it = Add-Row 'run' @($st[0], $x.repo, $title, $x.headBranch, $start.ToString('HH:mm'), (Span ($end - $start))) @{ url = $x.url; tone = $st[1]; hollow = $st[2] }
        $it.ToolTipText = "$($x.name)`n$title`n$($x.headBranch)"
        if ($x.url -eq $sel) { $it.Selected = $true }
    }
    $list.EndUpdate()
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
    # 요약 칩: 점 + 글자
    $x = 14
    foreach ($chip in @(('running', '실행 중'), ('queued', '대기'), ('failure', '최근 실패'))) {
        $n = $script:summary[$chip[0]]
        $text = "$($chip[1]) $n"
        $w = [Windows.Forms.TextRenderer]::MeasureText($text, $fontBold).Width + 26
        $rect = New-Object Drawing.Rectangle($x, 44, $w, 24)
        $tone = if ($n) { $T[$chip[0]] } else { $T.muted }
        $b = New-Object Drawing.SolidBrush($T.surface); $g.FillRectangle($b, $rect); $b.Dispose()
        $p = New-Object Drawing.Pen($T.border); $g.DrawRectangle($p, $rect); $p.Dispose()
        $b = New-Object Drawing.SolidBrush($tone); $g.FillEllipse($b, ($x + 9), 52, 8, 8); $b.Dispose()
        [Windows.Forms.TextRenderer]::DrawText($g, $text, $fontBold, (New-Object Drawing.Rectangle(($x + 20), 44, ($w - 20), 24)), $(if ($n) { $T.fg } else { $T.muted }), $flags)
        $x += $w + 8
    }
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

$list.Add_DrawItem({
    param($s, $e)
    $tag = $e.Item.Tag
    $g = $e.Graphics
    $bgc = if ($e.Item.Selected -and $tag.kind -eq 'run') { $T.selected } else { $T.surface }
    $b = New-Object Drawing.SolidBrush($bgc); $g.FillRectangle($b, $e.Bounds); $b.Dispose()
    if ($tag.kind -eq 'section') {
        $r = New-Object Drawing.Rectangle(($e.Bounds.X + 10), ($e.Bounds.Y + 6), ($e.Bounds.Width - 20), ($e.Bounds.Height - 6))
        [Windows.Forms.TextRenderer]::DrawText($g, $e.Item.Text, $fontSection, $r, $T.muted, $flags)
    } elseif ($tag.kind -eq 'empty') {
        $r = New-Object Drawing.Rectangle(($e.Bounds.X + 30), $e.Bounds.Y, ($e.Bounds.Width - 40), $e.Bounds.Height)
        [Windows.Forms.TextRenderer]::DrawText($g, $e.Item.Text, $fontBody, $r, $T.muted, $flags)
    }
})

$list.Add_DrawSubItem({
    param($s, $e)
    $tag = $e.Item.Tag
    if ($tag.kind -ne 'run') { return }
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
    $bd = $e.Bounds
    if ($e.ColumnIndex -eq 0) {
        $tone = $T[$tag.tone]
        $cy = $bd.Y + [int](($bd.Height - 8) / 2)
        if ($tag.hollow) { $p = New-Object Drawing.Pen($tone, 1.6); $g.DrawEllipse($p, ($bd.X + 12), $cy, 8, 8); $p.Dispose() }
        else { $b = New-Object Drawing.SolidBrush($tone); $g.FillEllipse($b, ($bd.X + 12), $cy, 8, 8); $b.Dispose() }
        $r = New-Object Drawing.Rectangle(($bd.X + 26), $bd.Y, ($bd.Width - 28), $bd.Height)
        [Windows.Forms.TextRenderer]::DrawText($g, $e.SubItem.Text, $fontBold, $r, $tone, $flags)
        return
    }
    $font = if ($e.ColumnIndex -ge 4) { $fontNum } else { $fontBody }
    $color = if ($e.ColumnIndex -in 1, 2) { $T.fg } else { $T.muted }
    $r = New-Object Drawing.Rectangle(($bd.X + 10), $bd.Y, ($bd.Width - 14), $bd.Height)
    [Windows.Forms.TextRenderer]::DrawText($g, $e.SubItem.Text, $font, $r, $color, $flags)
})

# --- 작업표시줄 막대 --------------------------------------------------------
# kindsusu/codex-usage-widget의 작업표시줄 막대와 같은 방식: 계층(layered) 창을 WS_CHILD로 바꿔 작업표시줄(Shell_TrayWnd) 안에 붙이고
# 직접 그린 비트맵을 UpdateLayeredWindow로 올린다. Windows 11 작업표시줄은 XAML 합성 층이 덮어서 보통 자식 창은 안 보인다.
# 그 위젯 막대는 작업표시줄 왼쪽을 쓰므로, 이 막대는 알림 영역(TrayNotifyWnd) 바로 왼쪽에 둔다.
# 순서가 중요하다: 처음부터 계층·숨김 상태로 만든다 → 자식으로 붙인다 → 그린다 → 보인다.
# WinForms 폼을 먼저 띄워 놓고 바꾸는 방식은 UpdateLayeredWindow가 성공해도 화면에 나타나지 않았다(2026-10-28 실측).
# ponytail: 빈 자리를 찾지 않고 알림 영역 왼쪽에 고정한다. 작업표시줄 아이콘을 왼쪽 정렬하고 앱을 많이 띄우면 겹칠 수 있다.
# ponytail: 막대 크기·글꼴은 100% 배율(96 DPI) 기준이다. 배율을 올리면 막대가 작게 보인다.
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class CiStripWindow : NativeWindow {
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    public event EventHandler LeftClick, RightClick;
    public CiStripWindow() {
        var cp = new CreateParams();
        cp.Caption = "CI status strip";
        cp.Style = unchecked((int)0x80000000);                 // WS_POPUP, 아직 숨김
        cp.ExStyle = 0x00080000 | 0x08000000 | 0x00000080;     // WS_EX_LAYERED | NOACTIVATE | TOOLWINDOW
        cp.Width = 1; cp.Height = 1;
        IntPtr old = SetThreadDpiAwarenessContext(new IntPtr(-4));   // 작업표시줄과 같은 실제 픽셀 좌표계
        try { CreateHandle(cp); } finally { SetThreadDpiAwarenessContext(old); }
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0021) { m.Result = new IntPtr(3); return; }                 // WM_MOUSEACTIVATE → MA_NOACTIVATE
        if (m.Msg == 0x0202 && LeftClick != null) LeftClick(this, EventArgs.Empty);   // WM_LBUTTONUP
        if (m.Msg == 0x0205 && RightClick != null) RightClick(this, EventArgs.Empty); // WM_RBUTTONUP
        base.WndProc(ref m);
    }
}
"@
$StripW = 118; $StripH = 40
$script:stripParent = [IntPtr]::Zero
$script:stripBack = $T.bg
$stripMenu = New-Object Windows.Forms.ContextMenuStrip
[void]$stripMenu.Items.Add('창 열기/숨기기', $null, { Toggle-Main })
[void]$stripMenu.Items.Add('새로고침', $null, { $script:tick = 0; Start-Fetch })
[void]$stripMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$stripMenu.Items.Add('종료', $null, { Exit-App })
function New-StripWindow {
    $w = New-Object CiStripWindow
    $w.add_LeftClick({ Toggle-Main })
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
    $tones = if ($light) { @{ running = C '#0369A1'; queued = C '#B45309' } } else { @{ running = $T.running; queued = $T.queued } }
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

function Attach-Strip {
    $N = [CiWidget.Native]
    $tb = $N::FindWindow('Shell_TrayWnd', $null)
    if ($tb -eq [IntPtr]::Zero) { return }
    $rb = New-Object CiWidget.Native+RECT; [void]$N::GetWindowRect($tb, [ref]$rb)
    $right = $rb.Right
    $tray = $N::FindWindowEx($tb, [IntPtr]::Zero, 'TrayNotifyWnd', $null)
    if ($tray -ne [IntPtr]::Zero) { $rt = New-Object CiWidget.Native+RECT; [void]$N::GetWindowRect($tray, [ref]$rt); $right = $rt.Left }
    $x = $right - $rb.Left - $StripW - 8
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
        $form.FormBorderStyle = 'None'; $form.MinimumSize = '0,0'; $form.Size = '330,48'
    } else {
        $miniBar.Visible = $false; $head.Visible = $true; $list.Visible = $true
        $form.FormBorderStyle = 'Sizable'; $form.Size = $script:fullSize; $form.MinimumSize = '560,260'
    }
    # 오른쪽 아래 모서리를 기준으로 제자리에서 접고 펼친다(화면 밖으로 나가지 않게)
    $wa = [Windows.Forms.Screen]::FromRectangle($r).WorkingArea
    $x = [Math]::Max($wa.Left, [Math]::Min($r.Right - $form.Width, $wa.Right - $form.Width))
    $y = [Math]::Max($wa.Top, [Math]::Min($r.Bottom - $form.Height, $wa.Bottom - $form.Height))
    $form.Location = New-Object Drawing.Point($x, $y)
    $expand.Location = New-Object Drawing.Point(($miniBar.Width - $expand.Width - 10), [int](($miniBar.Height - $expand.Height) / 2))
    if (-not $Snapshot) { try { [IO.File]::WriteAllText($modeFile, $(if ($on) { 'mini' } else { 'full' })) } catch {} }
}
function Toggle-Main {
    if ($form.Visible -and $form.WindowState -ne 'Minimized') { $form.Hide() }
    else { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() }
}
function Exit-App { $script:exiting = $true; $timer.Stop(); if ($script:sw) { $script:sw.DestroyHandle() }; $form.Close(); [Windows.Forms.Application]::Exit() }
# 창의 X는 작업표시줄 막대로 숨기기만 한다(종료는 막대 오른쪽 클릭 메뉴)
$form.Add_FormClosing({ param($s, $e) if (-not $script:exiting -and $e.CloseReason -eq 'UserClosing') { $e.Cancel = $true; $form.Hide() } })
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
# '내용' 칸이 남는 폭을 채워 머리글 오른쪽에 빈 칸(흰 띠)이 생기지 않게 한다
function Fit-Columns {
    $other = 0; foreach ($i in 0, 1, 3, 4, 5) { $other += $list.Columns[$i].Width }
    $list.Columns[2].Width = [Math]::Max(160, $list.ClientSize.Width - $other)
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
})
$form.Add_Shown({
    if ($startMini) { Set-Mini $true }
    try { Attach-Strip } catch { $script:note = "작업표시줄: $($_.Exception.Message)"; $_ | Out-File (Join-Path $env:TEMP 'ci-widget-strip.err') }
    Start-Fetch; $timer.Start()
})
# 창을 숨겨도 계속 돌도록 창 없는 메시지 루프로 돌린다(종료는 Exit-App)
$form.Show()
[Windows.Forms.Application]::Run((New-Object Windows.Forms.ApplicationContext))
