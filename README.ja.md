# Keychron C100 Codex ステータスデーモン

[English](README.md) | 日本語

Codex のライフサイクルフックを Keychron C100 8K のキーごとの RGB LED に反映する、macOS 向けのデーモン・CLI・メニューバーアプリです。タスクごとにキーを割り当て、LED で状態を確認し、キーを押して対象のタスクを開けます。C100 の通常の文字入力を抑制し、物理的な 10 × 10 のキーマトリクスから押された位置を読み取ります。

OpenAI、Keychron、QMK とは関係のない、非公式・実験的な個人プロジェクトです。macOS 13 以降を対象とし、動作確認した機種は VID `0x3434`、PID `0x042c` の Keychron C100 8K のみです。Codex の状態はフックとローカルのタスクデータから取得し、アクションは C100 から USB キーボード入力として送信します。

## メニューバーアプリ

`scripts/build-app.sh` でビルドし、`.build/C100 Companion.app` を `~/Applications` にコピーして開きます。メニューから接続状態の確認、レイヤー切り替え、LED の明るさ変更、デーモンの再起動、設定やログの表示ができます。詳しくは[アプリガイド](docs/companion-app.md)を参照してください。

設定画面には、次のタブがあります。

- **レイアウト**：キーをクリックして、右側パネルで機能を選択・検索・編集します。パーツはドラッグで移動でき、タスクエリアの幅・高さ・縦横の向きも変更できます。割り当てモーダルは表示しません。
- **アクション**：共通アクションに対して各サービスへ送るキーを一覧表示します。Codex から読み取った設定、Claude の内蔵既定値、未対応の組み合わせを区別します。
- **サービス**：利用するサービス、初期表示、プロファイルやデータのパスを設定します。ここで有効にしたサービスだけが、アクションの候補・送信先になります。

キーには「タスクをアーカイブ」「モデル選択」などの操作を一つ割り当て、前面アプリに応じて送信キーを選びます。同じ操作を複数のキーに割り当てることもできます。Claude Desktop の内蔵対応は Code タブ用です。Claude 本体の現在のショートカット設定の読み取り、および Claude のアーカイブ送信経路は未対応です。Claude CLI・herdr のキー送信も未対応で、タスクの状態表示・移動とは別の機能です。

詳しくは[レイアウトエディタ](docs/layout-editor.md)を参照してください。

## 設定

マシンごとのパスやデバイス設定は、`~/.config/c100-status/config.json` に保存します。`XDG_CONFIG_HOME` が設定されている場合は、`$XDG_CONFIG_HOME/c100-status/config.json` を使います。

```sh
c100-status config init                 # 設定のひな形を作成。既存ファイルは上書きしません
c100-status config show                 # 実際に適用される設定を表示
c100-status install-agent --config ~/.config/c100-status/config.json
```

エージェントをインストール・再起動する前に設定を編集してください。専用ファームウェアを書き込み済みの C100 では、`backend` を `companion` にします。Claude のプロファイルは `claudeConfigDirs` に指定します。このリストは既定のディレクトリ一覧を置き換えます。

設定項目と優先順位は[設定例](config.example.json)と[設定リファレンス](docs/configuration.md)を参照してください。

## 導入：専用ファームウェアが必要です

**[専用ファームウェアの導入・復元ガイド](firmware/FLASHING.ja.md)から始めてください。** 対象機種の確認、ビルド、K00 での DFU 起動、元のフラッシュのバックアップ、書き込み、読み戻し照合、復元まで順に説明しています。ビルドコマンドだけでは本体を書き換えません。

`run` は専用ファームウェアを要求し、未対応の本体では handshake に失敗します。通常入力を抑えられないまま動き続けることはありません。書き込み後の C100 は専用コントローラーとなり、デーモンが動いていない間は文字入力しません。

### アプリとログイン時の起動

ファームウェアを導入した後、このリポジトリで実行します。

```sh
swift build -c release
.build/release/c100-status self-test
scripts/build-app.sh --skip-build
mkdir -p "$HOME/Applications"
ditto '.build/C100 Companion.app' "$HOME/Applications/C100 Companion.app"
"$HOME/Applications/C100 Companion.app/Contents/MacOS/c100-status" config init
```

`config init` は既存設定を上書きしません。設定ファイルを確認してから起動します。`backend` は `companion` を指定します。省略した場合も `companion` です。

```sh
"$HOME/Applications/C100 Companion.app/Contents/MacOS/c100-status" install-agent
open "$HOME/Applications/C100 Companion.app" --args app --layout
"$HOME/Applications/C100 Companion.app/Contents/MacOS/c100-status" inspect
```

`connected: true`、`backend: companion`、USB 出力対応の新しいファームウェアなら `actionTransport: keyboard-hid` を確認します。実行ファイルを PATH に入れていない場合、この README の `c100-status` は上記の絶対パスに読み替えてください。

LaunchAgent は `~/Library/LaunchAgents/com.kotainaba.c100-status.run.plist` に登録され、ログイン時に起動し、終了すると launchd が再起動します。`--label` でラベル、`--binary` で実行ファイルを変更できます。`install-agent --dry-run` は登録内容の確認だけ、`install-agent --uninstall` は停止・登録解除です。`run` と `install-agent` は root で実行しません。

アプリ更新時は未保存の編集を保存し、デーモンとアプリを停止してからコピーし直します。`install-agent` を再実行すると登録済みプロセスも再起動します。手動の `run` や watcher と二重起動しないでください。

### 入力・権限・LED

- root ヘルパーと入力監視の登録は不要です。USB キーボード出力対応ファームウェアでは、アクション送信のアクセシビリティ権限も不要です。
- Ghostty のタブ移動に使う Apple Events の Automation 権限は別です。
- 通常の文字入力はファームウェアで抑制します。デーモンが物理押下を確認し、前面アプリと有効サービスを検査してから、登録したキーの送信を許可します。
- 他のキーボードは変更しません。対象は VID `3434` / PID `042c` と選択した `locationID` に限定します。
- LED とキー割り当ては揮発性で、`SaveLedConf` や EEPROM 保存は使いません。通信が途絶えると約 3 秒で消灯し、保留中の出力を解除します。通常キーボードに戻すにはファームウェアの復元が必要です。
- 物理位置をマトリクスから取得するので、同じ操作を複数キーに割り当てられます。
- Keychron Launcher を閉じ、デーモンと診断用 watcher を同時に使わないでください。

LED は 0 始まりの `row * 10 + column`、範囲 `0...99` です。色名は `off`、`white`、`red`、`green`、`blue`、`amber` を使えます。

```sh
c100-status ping
c100-status inspect
c100-status logs
tail -f "$(c100-status log-path)"
```

## デーモンの dry-run

ターミナル 1：

```sh
.build/release/c100-status run --dry-run
```

ターミナル 2：

```sh
.build/release/c100-status ping
printf '%s' '{"session_id":"dry-run","hook_event_name":"PermissionRequest"}' \
  | .build/release/c100-status hook
.build/release/c100-status logs
```

状態遷移を記録しますが、HID へのアクセスは行いません。

## Codex フック

先にデーモンを起動します。次に `hooks.example.json` を信頼する Codex フック設定にコピーし、`/ABSOLUTE/PATH/TO/c100-status` を release 実行ファイルの絶対パスに置き換えます。管理対象外のフックは、Codex 側で内容を確認して信頼する必要があります。

| Codex イベント | LED の状態 |
| --- | --- |
| `SessionStart` | 白（`idle`） |
| `UserPromptSubmit`、`PostToolUse` | 青（`working`） |
| `PermissionRequest` | ユーザー承認に回る場合のみ、500 ms 待って橙（`approval`） |
| `PreToolUse` | 青（`working`）。保留中の承認表示を取り消す |
| `Stop` | 緑（`done`） |
| `SessionEnd` | カタログにタスクが残っていれば白（`idle`） |

各フックは短時間だけ動く送信プロセスです。デーモンはプロジェクトを行、その中のタスクを列に配置します。プロジェクト行は空の行も含めて Codex の保存済み `project-order` に従います。タスクはピン留め・明示的なサイドバー順、その後は最近の利用順です。プロジェクトに属さないタスクは、作業ディレクトリごとではなく最後の `projectless` 行にまとめます。

標準レイアウトでは上 8 行に、各プロジェクトのタスクを一度に 10 個ずつ表示します。表示範囲外のプロジェクトやタスクも追跡し、縦・横スクロールで移動できます。横スクロール位置は全プロジェクト行で共通です。タスクエリアのサイズ・配置・縦横の向きを変えた場合は、その設定に従います。

カタログとサイドバー状態を 2 秒ごとに再読み込みするため、プロジェクトやタスクの追加・並べ替えはデーモンの再起動なしで反映され、状態色もタスクと一緒に移動します。

フックの `session_id` がまだ Codex アプリのカタログにない場合は、最大 6 秒だけメモリに保持します。その間にタスクが現れれば最新の状態を反映し、現れなければ内部実行・アプリ外セッションとして破棄します。これにより、実行器側の `PostToolUse` が架空のキーを作っては解放する現象を防ぎます。Codex が提供する `turn_id`、`agent_id`、`agent_type` も診断用ログに記録します。

待機中のキーは白（`idle`、HSV の V は 96/255）です。動作中・承認待ち・完了・エラーでは一時的に青・橙・緑・赤へ変わります。`SessionEnd` は白に戻し、カタログからタスクが消えたときだけ消灯・解放します。

`PermissionRequest` は、自動レビューかユーザーへの確認かを Codex が決める前に発火するため、それだけでは承認待ちと判断しません。フックの `tool_name` とロールアウトの `approvals_reviewer` を確認し、明示的な `request_permissions`、または `user` レビュアーの場合だけ 500 ms 後に橙にします。`auto_review` / `guardian_subagent`、または判別できない場合は青のままにし、誤ったユーザー待ち表示を避けます。後続のイベントで保留状態を解消します。

緑（`done`）のタスクキーを押し、Codex への移動に成功すると完了を確認したものとして白に戻します。他の動作中の色は変えません。

Esc によるターン中断では Codex は `Stop` を送らないため、2 秒ごとの同期で各タスクのローカルロールアウトを追跡します。新しい `turn_aborted` を検出すると、そのタスクだけを青・橙から白へ戻します。

プロジェクトの特定では、明示的な「プロジェクトなし」指定と Codex のタスク割り当てを優先します。割り当てやカタログ上のプロジェクト ID がないタスクでは、保存済みプロジェクトルートとの最長一致を使い、複数ルートや workspace-root の情報も考慮します。曖昧な場合はプロジェクトなしにします。解決したプロジェクト ID でグループ化するため、同じ作業ディレクトリを共有する別プロジェクトが混ざることはありません。

プロジェクトなしの行は名前付きプロジェクトの後ろに並び、他の行と同じようにスクロールします。物理的な最下段に固定するわけではありません。表示範囲外の状態も保持します。[スクロール操作](docs/scrolling.md)も参照してください。

フォークは、記録されたフォーク元・サブエージェントの系譜をたどって元タスクのプロジェクトを継承します。同じディレクトリのフォークも別 worktree のフォークも、元プロジェクトの行の別列・別キーに配置します。

割り当て済みキーを押すと `codex://threads/<session_id>` を開きます。Codex が起動済みなら 1 回で移動します。未起動なら同じキーを 350 ms 以内に 2 回押したときだけ、Codex を起動して移動します。

## Claude Code（herdr・ターミナル・Claude Desktop）

herdr、通常のターミナル（Ghostty）、Claude Desktop 内の Claude Code セッションに対応しています。それぞれ独立したレイヤーで表示し、状態は主に Claude Code フックから取得します。

サブエージェントが 1 個以上動いているセッションは、親が待機状態になっても青（`working`）を保ちます。`SubagentStart` / `SubagentStop` で追跡し、最後のサブエージェントが終了すると親自身の状態に戻します。終了フックの取りこぼしに備え、開始から 2 時間で追跡を失効させます。また、開始から 30 分を超えた個々のサブエージェントについて、自身の transcript が新しいと確認できない場合も追跡から除きます。

### Claude Code フックの導入

Claude Code は `claudeConfigDirs` に指定した各プロファイルの `settings.json` からフックを読みます。既定は `$CLAUDE_CONFIG_DIR`、未設定なら `~/.claude` です。

```sh
c100-status install-claude-hooks --dry-run   # 変更予定を表示
c100-status install-claude-hooks             # 実際に書き込み
```

対象は設定済みの `claudeConfigDirs` だけです。別のディレクトリ群を使う場合は `--config-dir PATH` を必要な回数指定します。実行ファイルのパスは自動検出しますが、`--binary PATH` で明示できます。

再実行しても `c100-status` 所有の項目だけを追加・更新し、他のフックは変更しません。書き込み前には、既存ファイルを同じディレクトリの `settings.json.c100-backup-<epoch-ms>` に保存します。`--uninstall` は `c100-status` の項目だけを削除します。`settings.json` がないディレクトリは警告してスキップし、ファイルを新規作成しません。JSON を解釈できない場合も変更せずエラーを報告します。Claude Code 側で管理対象外フックを確認・信頼する手順は必要です。

手動の場合は `hooks.claude.example.json` を各プロファイルの `settings.json` にマージし、`/ABSOLUTE/PATH/TO/c100-status` を release 実行ファイルの絶対パスに置き換えます。

herdr も使う場合、同じ `settings.json` にある `hooks/herdr-agent-state.sh` の項目を編集・置換せず、`c100-status hook --source claude` を配列の追加要素として登録してください。各イベント配列には複数フックを置けます。herdr が自身の設定変更で `settings.json` を再生成すると `c100-status` の項目が失われることがあるため、その場合は `install-claude-hooks` を再実行します。

### herdr 連携

`run` の動作中、専用バックグラウンドスレッドが `herdr agent list` と `herdr workspace list` を 2 秒ごとに取得します。10 ms 間隔の HID ポーリングとは独立しているため、herdr の応答が遅くてもキー入力を待たせません。`"agent":"claude"` の項目だけが対象です。

- **行**：workspace の `workspace_id` / `number` を使い、番号順に配置します。
- **列**：workspace 内でタブ番号、ペインの上→下・左→右、ペイン番号の順に並べ、0 から隙間なく割り当てます。ペイン番号そのものを列番号にはしません。
- **初期状態**：`agent_status` の `idle` / `working` / `blocked` / `done` / `unknown` を、それぞれ `idle` / `working` / `approval` / `done` / `idle` として扱います。最初のフック以降はフックを優先します。その後フックが届かず、herdr が 2 回連続で `idle` / `done` を返した場合は、取りこぼしからの復旧として herdr の状態を反映します。

herdr の一覧取得が失敗した場合は、最後の正常な結果を 15 秒間保持します。短い障害で画面全体が消えないようにするためです。ペインが閉じるなどして正常な一覧からセッションが消えた場合は、そのキーを直ちに解放します。

キーを押すと `herdr agent focus <pane_id>` を実行し、その後 `NSWorkspace` で Ghostty（`com.mitchellh.ghostty`）を前面にします。herdr の focus は 200 ms のタイムアウト付きベストエフォートで、失敗はログに記録します。Ghostty がなければ、その旨を記録して移動は行いません。

### herdr 実行ファイルの検出

次の順で検索します。

1. `--herdr-bin PATH`
2. 設定の `herdrBinary`
3. 環境変数 `HERDR_BIN`
4. `PATH` 内の絶対ディレクトリ
5. `/opt/homebrew/bin/herdr`
6. `/usr/local/bin/herdr`
7. `~/.cargo/bin/herdr`

実行可能なファイルが見つからない場合は、起動時に INFO ログを 1 行記録し、herdr 連携を無効にして他の処理を続けます。

### 通常のターミナル（Ghostty）での Claude Code

herdr や Claude Desktop を介さずに起動した `claude` は、次の二つを使って追跡します。

- **状態はフックを正本とします。** 同じ `c100-status hook --source claude` がセッションを登録・更新します。
- **配置は `sessions/<pid>.json` を正本とします。** 各 `claudeConfigDirs` の `<configDir>/sessions/<pid>.json` を 2 秒ごとに読み、`kill(pid, 0)` で生存を確認し、`cwd` でグループ化します。使うフィールドは `pid`、`sessionId`、`cwd` で、その他は無視します。起動前から動いていたセッションも、次のフックを待たずに取り込めます。

ファイルは `O_NOFOLLOW` で開いてシンボリックリンクを拒否し、64 KiB を上限にします。大きすぎるファイルや通常ファイルでないものはスキップします。

同じセッションを herdr とターミナル走査の両方で見つけた場合は herdr を優先し、配置が往復するのを防ぎます。終了フックがなくても、セッションファイルの消失や PID の終了を次回同期で検出して削除します。また、herdr・ターミナル・Desktop 共通の保険として、フック登録済みセッションの transcript `.jsonl` が 30 分更新されなければ放置されたものとして除去します。

キーを押すと Ghostty に AppleScript を送り、開いているウィンドウ・タブ・ターミナルから `working directory` が `cwd` と完全一致するものを探して選択します。同じ `cwd` が複数ある場合は最初の一致を使います。Ghostty の AppleScript 辞書にはターミナルの PID がなく、既存ターミナルの環境変数も読み取れないため、`cwd` で照合します。

`cwd` はスクリプト文字列に埋め込まず、`osascript` の `argv` 引数として渡します。1 秒でタイムアウトし、失敗、Automation 権限不足、該当タブなしの場合は理由をログに残して Ghostty を前面にするだけに切り替えます。初回は macOS から Ghostty の操作許可を求められる場合があります。**システム設定 → プライバシーとセキュリティ → オートメーション**で許可するまでは、特定タブへの移動は行いません。

### Claude Desktop 内のセッション

`CLAUDE_CODE_ENTRYPOINT=claude-desktop` で識別します。transcript 用プロファイルの既定は `~/.claude` です。異なる場合は `claudeDesktopConfigDir` を設定し、フック導入時にはそのプロファイルを `claudeConfigDirs` にも含めます。状態はフックを正本とし、ファイル走査は起動済みセッションの取り込みと、終了通知がないセッションの除去に使います。

Desktop は `~/Library/Application Support/Claude/claude-code-sessions/<accountId>/<workspaceId>/local_<uuid>.json` にセッションを保存します。走査ルートは `--claude-desktop-dir` で変更できます。ファイル内の `sessionId` は `local_` 付きの Desktop 内部 ID で、デーモンが使うのはフックの `session_id` や transcript 名に一致する **`cliSessionId`** です。同じディレクトリの `scheduled-tasks.json` は無視します。

`isArchived: false` で、次のいずれかを満たすセッションを有効とします。

- `lastActivityAt` が 6 時間以内。
- transcript `.jsonl` の更新が 6 時間以内。
- デーモンが既に `claude-desktop` としてフック登録している。

フックを受信済みのセッションは走査時刻が古いだけでは除去しません。Claude Desktop（`com.anthropic.claudefordesktop`）が起動していなければ、走査結果は空にします。

**現在の実装では、Desktop の特定セッションへの直接移動に対応していません。** 承認待ち（`approval`）のキーでは `claude://code/needs-input` を開き、セッション横断の入力待ち一覧を表示します。それ以外は `NSWorkspace` で Claude Desktop を前面にします。これは実装時に利用できた経路に基づく制限であり、将来のアプリや URL スキーム全体の機能を保証する記述ではありません。

Claude Desktop 内の Claude Code は SDK モードで動作します。`Notification` の `permission_prompt`、`idle_prompt`、`agent_needs_input`、`agent_completed` が対話型 TUI と同じように発火するかは、すべてのケースで確認していません。Desktop の承認待ちでは、ツールの権限確認ごとに発火する `PermissionRequest` を主な信号として使います。想定どおり橙にならない場合は、`/tmp/keychron-c100-status-<uid>.log` で届いているイベントを確認してください。

## レイヤー（サービスごとのグリッド）

Codex Desktop、herdr、通常のターミナルの Claude Code、Claude Desktop の四つの独立したグリッドを切り替えます。タスクエリアに表示するのは一度に一つのレイヤーです。各レイヤーは独立したプロジェクト・行の管理情報を持つため、異なるサービスで同じ `cwd` を使っても行を取り合いません。

以下は**標準レイアウト**の説明です。コンパニオンで再配置した場合は、保存したレイアウトに従います。

下 2 行（キー 80〜99）はユーティリティ行です。88 が上、97 / 98 / 99 が左 / 下 / 右で、横移動は全プロジェクト行を一緒に動かします。80〜87 は未割り当て、90〜93 はレイヤー切り替え、89 と 94〜96 は消灯です。矢印は長押しで連続移動できます。

| キー | レイヤー | 基本色 | 意図 |
| --- | --- | --- | --- |
| 90 | Codex | 青紫・indigo（約 `#5B5BF5`〜`#6466F1`） | Codex のブランドカラーに合わせる |
| 91 | herdr | 明るい青（`#4a9eff`） | herdr.dev の既定テーマの `--accent` に合わせる |
| 92 | Claude CLI | Claude の橙（約 `#D97757`） | Claude のコーラル・テラコッタ系カラー |
| 93 | Claude Desktop | Claude 系の色を赤・バーガンディ寄りにして暗めにする | CLI と見分けやすくする |

切り替えキーを押すと即座にレイヤーを変更し、`/tmp/keychron-c100-status-<uid>-layer.json` に保存します。初回、または保存ファイルがない・壊れている場合の既定は Codex で、`defaultLayer` で変更できます。有効な保存済み選択があればそちらを優先します。

非表示のレイヤーに `approval`、`error`、`done` のセッションがあると、この優先順で切り替えキーを点滅させます。約 600 ms ごとに基本色と状態色を交互に表示します。表示中レイヤーの切り替えキーは点滅せず、選択状態の明るさで表示します。最終的な明るさには全体の明るさ設定も反映します。基本色と状態色が近い場合でも、点滅で注意が必要なことを見分けられます。

非表示レイヤーのフックやカタログ更新も継続しますが、切り替えるまではタスクエリアを再描画しません。タスクキーでの移動と、完了キーを押して白に戻す操作は、表示中のレイヤーだけに適用します。

## 実行時のパスとオプション

- ソケット：`/tmp/keychron-c100-status-<uid>.sock`。デーモン・クライアント双方の `--socket PATH` で変更できます。
- ログ：`/tmp/keychron-c100-status-<uid>.log`。`run`、`logs`、`log-path` の `--log-file PATH` で変更できます。
- デバイス：複数の C100 から選ぶ場合、`run` に `--location` と対象の接続位置を指定します。
- Claude Code のプロファイル：`claudeConfigDirs` または `--claude-config-dirs PATH1,PATH2` で走査対象を置き換えます。個人用の名前付きプロファイルを暗黙には追加しません。
- Claude Desktop のセッション：既定は `~/Library/Application Support/Claude/claude-code-sessions`、変更は `--claude-desktop-dir PATH` です。
- 専用ファームウェアとの handshake が成立しなければデバイスを制御しません。

`apply <status>` はデーモンを介さず HID に直接書き込みます。デーモンと Keychron Launcher を停止した状態でのトラブルシューティングに限って使ってください。

## アンインストール

LaunchAgent として登録している場合は先に解除します。

```sh
.build/release/c100-status install-agent --uninstall
```

手動起動の場合は Ctrl-C で停止します。ユーザー所有の実行時ソケット・状態ログ・ローカル Codex データは削除しません。

## 現在の制限

`clear` は揮発性の状態表示をクリアします。元の通常キーボード用ファームウェアや RGB 設定を復元する機能ではありません。復元は[導入・復元ガイド](firmware/FLASHING.ja.md)に従ってください。

既存タスクの初期取り込みには、Codex のローカル SQLite カタログを使います。失敗してもデーモン全体を停止せず、ログに記録します。フック受信自体は独立して続きますが、Codex のタスク配置には前述のカタログとの照合があります。

## ライセンスとプロトコル資料

このリポジトリの独自 Swift ソースは MIT ライセンスです。[LICENSE](LICENSE)を参照してください。相互運用性に関する注記と第三者への謝辞は [NOTICE.md](NOTICE.md) にあります。

## ブラウザからファームウェアを導入する

[Web Flasher（実験版）](https://shiroinock.github.io/codex-macro/) は、macOS の Chrome 向けのバックアップ・書き込み・復元サイトです。保存したバックアップの再選択と照合を必須にし、書き込み後は読み戻してから再起動します。バックアップをサーバーへ送信しません。実機でバックアップ保存・書き込み・読み戻し照合・再起動後の Companion 動作を確認済みです。初回バックアップから通常ファームウェアへの復元・文字入力と、専用ファームウェアへの再導入も確認済みです。CLI による確認済みの手順は [導入・復元ガイド](firmware/FLASHING.ja.md) を参照してください。
