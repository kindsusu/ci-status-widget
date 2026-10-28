# ci-status-widget

GitHub Actions 실행 현황을 Windows 바탕화면 팝업과 작업표시줄에 띄워 두는 작은 위젯입니다.
자체 호스팅 실행기(self-hosted runner) 한 대를 여러 저장소가 같이 쓸 때, 지금 무엇이 돌고 무엇이 줄 서 있는지 한눈에 보려고 만들었습니다.

- **팝업 창**: 진행 중 / 최근 완료 20건(상태·저장소·내용·브랜치·시작·걸린 시간). 행을 더블클릭하거나 Enter를 누르면 GitHub 실행 화면이 열립니다.
- **미니 모드**: `실행 중 N · 대기 N`만 보이는 작은 막대. 끌어서 옮기고, 두 번 클릭하거나 `펼치기`로 돌아갑니다. 마지막 모드를 기억합니다.
- **작업표시줄 막대**: 알림 영역 바로 왼쪽에 `실행 중 N / 대기 N`. 클릭하면 창을 열고 숨기며, 오른쪽 클릭하면 새로고침·종료 메뉴가 나옵니다.
- 3분마다 갱신합니다(`refreshSeconds`). `새로고침` 버튼으로 바로 갱신할 수 있습니다.

## 필요한 것

- Windows 10/11, Windows PowerShell 5.1(기본 설치)
- [GitHub CLI](https://cli.github.com/) `gh`가 설치되어 있고 `gh auth login`으로 로그인된 상태. 위젯은 `gh run list`로만 조회합니다.
- PowerShell 실행 정책이 로컬 스크립트를 허용해야 합니다(`RemoteSigned` 등).

## 설치

1. 이 저장소를 받습니다.
2. `config.example.json`을 `config.json`으로 복사하고 조직과 저장소를 적습니다. `config.json`은 git에 올라가지 않습니다.

   ```json
   {
     "org": "your-org",
     "repos": ["repo-a", "repo-b"],
     "refreshSeconds": 180
   }
   ```

3. 바로가기를 만듭니다. `-Startup`을 붙이면 로그인할 때 자동으로 실행됩니다.

   ```powershell
   .\install.ps1 -Startup
   ```

4. 바탕화면의 **CI 현황**을 실행합니다. 지우려면 `.\install.ps1 -Uninstall`.

## 쓰는 법

| 동작 | 결과 |
|---|---|
| 창의 X | 종료가 아니라 숨기기(작업표시줄 막대는 남음) |
| 작업표시줄 막대 클릭 | 창 열기 / 숨기기 |
| 작업표시줄 막대 오른쪽 클릭 | 창 열기/숨기기 · 새로고침 · 종료 |
| `미니 모드` / `펼치기` | 작은 막대로 접기 / 펼치기 |
| `항상 위` | 다른 창 위에 고정 |

## 작업표시줄 막대가 동작하는 방식

Windows 11 작업표시줄은 XAML 합성 층이 덮고 있어서, 다른 프로세스의 보통 자식 창을 붙이면 화면에 나타나지 않습니다.
그래서 계층(layered) 창을 만들어 `SetParent`로 `Shell_TrayWnd`의 자식으로 붙이고, 직접 그린 32비트 비트맵을 `UpdateLayeredWindow`로 올립니다.

순서가 중요합니다.

1. 처음부터 **계층·숨김 상태**로 창을 만든다(`WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`, `WS_POPUP`)
2. `WS_CHILD`로 바꾸고 `SetParent`로 작업표시줄에 붙인다
3. `UpdateLayeredWindow`로 그린다
4. `ShowWindow(SW_SHOWNOACTIVATE)`로 보인다

WinForms 폼을 먼저 띄워 놓고 스타일을 바꾸는 방식은 `UpdateLayeredWindow`가 성공해도 화면에 나타나지 않았습니다.
GDI+ `Bitmap.GetHbitmap()`은 알파를 잃으므로, 미리 곱한(PArgb) 픽셀을 `CreateDIBSection`으로 만든 DIB에 그대로 복사합니다.
같은 방식의 Python 구현은 [codex-usage-widget](https://github.com/kindsusu/codex-usage-widget)에 있습니다.

## 한계

- 막대는 알림 영역 바로 왼쪽에 고정됩니다. 작업표시줄 아이콘을 왼쪽 정렬하고 앱을 많이 띄우면 겹칠 수 있습니다.
- 막대 크기와 글꼴은 100% 배율(96 DPI) 기준입니다. 배율을 올리면 막대가 작게 보입니다.
- 목록의 세로 스크롤바는 밝은 색으로 남습니다.

## 확인용 옵션

```powershell
.\ci-widget.ps1 -Snapshot out.png        # 한 번 조회해 창 그림(out.png)과 막대 그림(out-strip.png)만 저장
.\ci-widget.ps1 -Snapshot out.png -Mini  # 미니 모드 그림
```

## 라이선스

MIT
