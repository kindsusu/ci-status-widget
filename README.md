# ci-status-widget

GitHub Actions 실행 현황을 Windows 바탕화면 팝업과 작업표시줄에 띄워 두는 작은 위젯입니다.
자체 호스팅 실행기(self-hosted runner) 한 대를 여러 저장소가 같이 쓸 때, 지금 무엇이 돌고 무엇이 줄 서 있는지 한눈에 보려고 만들었습니다.

- **팝업 창**: 진행 중 / 최근 완료 20건(상태·저장소·내용·브랜치·시작·걸린 시간). 위쪽 칩(전체·실행 중·대기·실패·완료)을 누르면 그 상태만 보입니다. 행을 더블클릭하거나 Enter를 누르면 GitHub 실행 화면이 열립니다.
- **미니 모드**: `실행 중 N · 대기 N`만 보이는 작은 막대. 끌어서 옮기고, 두 번 클릭하거나 `펼치기`로 돌아갑니다. 마지막 모드를 기억합니다.
- **작업표시줄 막대**: 기본은 알림 영역 바로 왼쪽에 `실행 중 N / 대기 N`(실행 중이면 초록 점). 좌우로 끌어 옮길 수 있고 그 자리를 기억합니다. 클릭하면 창을 열고 숨기며, 오른쪽 클릭하면 메뉴가 나옵니다.
- **숨기기**: 창의 `숨기기`(또는 X)로 감추면 작업표시줄 막대만 남습니다. 숨긴 상태를 기억해 다음 실행 때도 숨긴 채로 시작하고, 바로가기를 다시 실행하면 창이 다시 열립니다.
- 3분마다 갱신합니다(`refreshSeconds`). `새로고침` 버튼으로 바로 갱신할 수 있습니다.

## 필요한 것

- Windows 10/11, Windows PowerShell 5.1(기본 설치)
- [GitHub CLI](https://cli.github.com/) `gh`와 GitHub 로그인. 위젯은 `gh run list`로만 조회합니다.
  - **gh가 없으면** 위젯 창에 `gh 설치` 버튼이 나옵니다. 누르면 한 번 확인한 뒤 GitHub 공식 릴리스 zip을 받아 SHA-256을 확인하고 `%LOCALAPPDATA%\Programs\gh`에 풀고 사용자 PATH에 더합니다(관리자 권한 불필요, winget 없는 PC도 됨).
  - **로그인이 안 되어 있으면** `로그인` 버튼이 나옵니다. `gh auth login --web` 창이 열리고, 브라우저에서 코드를 입력해 승인하면 됩니다. 로그인은 본인 승인이 필요해 자동으로 할 수 없습니다.
  - 이 동안 작업표시줄 막대와 미니 모드는 `0 / 0` 대신 **확인 필요**로 보이고, 15초마다 다시 확인해 해결되면 바로 정상 화면으로 돌아옵니다.
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
| `숨기기` / 창의 X | 창 숨기기(작업표시줄 막대는 남음, 종료 아님) |
| 바탕화면 `CI 현황` 다시 실행 | 숨긴 창 다시 열기 |
| 작업표시줄 막대 클릭 | 창 열기 / 숨기기 |
| 작업표시줄 막대 좌우로 끌기 | 막대 옮기기(자리 기억). 사용량 위젯 막대와 겹치면 옆으로 비킴 |
| 막대를 끌어 다른 화면에 놓기 | 그 화면의 작업표시줄로 옮김(화면 위 아무 곳에 놓아도 됨) |
| 작업표시줄 막대 오른쪽 클릭 | 창 열기/숨기기 · 새로고침 · 작업표시줄 옮기기 · 막대 위치 초기화 · 종료 |
| 위쪽 상태 칩 클릭 | 전체 / 실행 중 / 대기 / 실패 / 완료만 보기 |
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

- 막대는 [codex-usage-widget](https://github.com/kindsusu/codex-usage-widget)·claude-usage-widget 막대만 피합니다. 작업표시줄 앱 아이콘 위에 놓으면 겹칩니다.
- 끄는 동안 막대는 원래 작업표시줄 안에서만 움직입니다(고스트 없음). 다른 화면으로 옮길 때는 커서를 그 화면에 놓으면 막대가 그쪽으로 넘어갑니다.
- 저장한 화면이 없으면(모니터를 뺀 경우 등) 저장값은 그대로 두고 주 작업표시줄에 띄웁니다.
- 사용량 위젯 쪽은 이 막대를 모르므로, 그쪽이 나중에 자리를 옮기면 겹칠 수 있습니다. 이때는 막대를 다시 끌어 놓으면 됩니다.
- 막대 크기와 글꼴은 100% 배율(96 DPI) 기준입니다. 배율을 올리면 막대가 작게 보입니다.
- 목록의 세로 스크롤바는 밝은 색으로 남습니다.

## 확인용 옵션

```powershell
.\ci-widget.ps1 -Snapshot out.png        # 한 번 조회해 창 그림(out.png)과 막대 그림(out-strip.png)만 저장
.\ci-widget.ps1 -Snapshot out.png -Mini  # 미니 모드 그림
```

## 라이선스

MIT
