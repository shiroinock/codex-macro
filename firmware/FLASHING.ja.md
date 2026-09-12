# C100 8K 専用ファームウェアの導入・復元

[README に戻る](../README.ja.md) · [English protocol/build reference](README.md)

C100 Companion は、**Keychron C100 8K（通常動作時の VID `3434` / PID `042c`）にこのリポジトリの専用ファームウェアを書き込んで使います**。他の C100 や別機種のイメージとして流用しないでください。標準ファームウェアを root grabber で使う方式は廃止しました。

書き込み後、C100 は通常の文字入力用キーボードではなく、コンパニオン専用の操作デバイスになります。デーモンが停止している間はキーを押しても文字を送りません。通常のキーボードを別に用意してください。割り当ては EEPROM に保存せず、デーモンが必要に応じて RAM に登録します。

このガイドは検証済みの C100 8K・AT32 DFU 構成を対象にしています。USB ID やフラッシュの表示が違う場合は、以下の数値をそのまま使わず、機種を確認してください。ファームウェアの動作は実験的です。[検証記録](VALIDATION.md)で確認済み・未確認の範囲を確認できます。

ブラウザで進める場合は [Web Flasher（実験版）](https://shiroinock.github.io/codex-macro/) も利用できます。macOS の Chrome 向けで、実機でバックアップ保存・書き込み・読み戻し照合・再起動後の Companion 動作を確認済みです。初回バックアップから通常ファームウェアへの復元・文字入力と、専用ファームウェアへの再導入も確認済みです。以下は CLI 方式の手順です。

## 1. 用意するもの

- 対象の C100 8K、データ通信可能な USB ケーブル、別のキーボード。
- macOS 13 以降、Swift をビルドできる Xcode / Command Line Tools。
- Git、Python 3、Docker 互換ランタイム（起動済み）。
- `dfu-util`。Homebrew を使う場合は `brew install dfu-util` で導入できます。
- 元のファームウェアを保存する空きディレクトリ。バックアップはこのデバイス専用として保管します。

以下は、このリポジトリのルートで、同じターミナルを使って実行する例です。説明用のパスや接続位置を、自分のマシンの値と混同しないでください。

## 2. ホストアプリをビルドして対象を確認する

```sh
swift build -c release
.build/release/c100-status self-test
.build/release/c100-status list
```

`list` の機種・VID・PID を確認します。`location` は USB ポートやマシンによって変わるため、後でこのマシンの値を使います。

Keychron Launcher を閉じます。既存の C100 デーモンが動いている場合は停止します。メニューバーの **C100 → デーモンを停止** を使います。メニューがない旧版では、ユーザー LaunchAgent を次のコマンドで停止できます：

```sh
.build/release/c100-status stop-agent
```

手動起動の `run` や診断用 watcher があれば、それも停止します。同じデバイスを複数のプロセスで制御しないでください。設定画面に未保存の編集があれば先に保存します。

## 3. ファームウェアと復元用イメージをビルドする

既存の作業ディレクトリを壊さないよう、新しい一時ディレクトリを作ります。

```sh
C100_BUILD_DIR=$(mktemp -d /tmp/c100-qmk.XXXXXX)
git clone --branch 2025q3 --single-branch https://github.com/Keychron/qmk_firmware.git "$C100_BUILD_DIR"
git -C "$C100_BUILD_DIR" checkout 9ada9b7baecb9591c469b9b068146ac5891a480a
git -C "$C100_BUILD_DIR" submodule update --init lib/chibios lib/chibios-contrib lib/printf lib/lufa
python3 scripts/prepare-companion.py "$C100_BUILD_DIR"
docker run --rm --network none -e SKIP_GIT=yes -e QMK_USERSPACE= \
  -v "$C100_BUILD_DIR:/qmk_firmware" -w /qmk_firmware \
  ghcr.io/qmk/qmk_cli@sha256:b7d7fa8fb4432b569931de5ad59098cb788f440ed61a62c5126746b71aee0f4a \
  make keychron/c100_8k:companion -j4
```

出力は `$C100_BUILD_DIR/keychron_c100_8k_companion.bin` です。初回は Docker イメージの取得にネットワークが必要ですが、コンテナ内のビルドは `--network none` で行います。

公開ソースから作る標準キーマップの復元用イメージも用意できます。

```sh
docker run --rm --network none -e SKIP_GIT=yes -e QMK_USERSPACE= \
  -v "$C100_BUILD_DIR:/qmk_firmware" -w /qmk_firmware \
  ghcr.io/qmk/qmk_cli@sha256:b7d7fa8fb4432b569931de5ad59098cb788f440ed61a62c5126746b71aee0f4a \
  make keychron/c100_8k:keychron -j4
```

出力は `keychron_c100_8k_keychron.bin` です。これは公開ソースのビルドであり、**自分のデバイスに元から入っていたバイナリや設定のバックアップではありません**。ビルド時刻などにより、同じソースでもハッシュが変わることがあります。

この段階では C100 本体は書き換わりません。

## 4. 書き込みモード（DFU）に入る

1. C100 の USB を抜きます。
2. **左上のキー K00** を押したまま USB を挿し直します。
3. 3 秒ほどしてキーを離します。
4. 次のコマンドで確認します。

```sh
dfu-util -l
```

検証した本体では DFU ID は `2e3c:df11`、内部フラッシュは alternate setting `0`、開始アドレスは `0x08000000`、容量は 256 KiB でした。通常動作時の USB ID とは異なります。

出力の `path="..."` を確認し、その値を設定してください。次の `2-1.1` は検証環境の**例**です。

```sh
C100_DFU_PATH='2-1.1'  # 必ず dfu-util -l に表示された自分の対象の path に変更
```

対象を ID・USB path・alt で限定します。該当機器が複数ある、内部フラッシュの構成が違う、DFU が見つからない場合は、書き込みへ進まないでください。

## 5. 元のフラッシュをバックアップする

新規ディレクトリに読み出し、元のバックアップを上書きしないようにします。

```sh
C100_BACKUP_DIR=$(mktemp -d "$HOME/c100-backup.XXXXXX")
dfu-util -d 2e3c:df11 -p "$C100_DFU_PATH" -a 0 \
  -s 0x08000000:262144 -U "$C100_BACKUP_DIR/original-flash.bin"
wc -c "$C100_BACKUP_DIR/original-flash.bin"
shasum -a 256 "$C100_BACKUP_DIR/original-flash.bin"
```

**正常終了し、262144 バイトであることを確認してから次へ進みます。** 読み出しに失敗した場合、読み出し保護の解除や mass erase で回避しないでください。これらは元の内容を失う可能性があります。

バックアップ、ハッシュ、`dfu-util -l` の結果、使用ソースの commit を保管します。別の C100 のバックアップを自分の本体へ書き戻さないでください。

## 6. 専用ファームウェアを書き込み、読み戻して照合する

まず、今回ビルドしたイメージのハッシュを記録します。

```sh
C100_IMAGE="$C100_BUILD_DIR/keychron_c100_8k_companion.bin"
shasum -a 256 "$C100_IMAGE"
```

**ここからが本体への書き込みです。** 上記の対象・バックアップ・イメージを確認して実行します。完了まで USB を抜かないでください。

```sh
dfu-util -d 2e3c:df11 -p "$C100_DFU_PATH" -a 0 \
  -s 0x08000000 -D "$C100_IMAGE"
```

このビルドの `.bin` には 16 バイトの DFU suffix が付きます。suffix はフラッシュに書かれないため、それを除いた payload と読み戻し結果を比較します。以下はこの形式を検査し、不一致なら停止する例です。

```sh
python3 - "$C100_IMAGE" "$C100_BACKUP_DIR/expected-payload.bin" <<'PY'
import pathlib, sys
image = pathlib.Path(sys.argv[1]).read_bytes()
assert len(image) > 16 and image[-8:-5] == b'UFD' and image[-5] == 16, '想定した DFU suffix ではありません'
payload = image[:-16]
assert 0 < len(payload) <= 262144, 'フラッシュ容量外です'
with open(sys.argv[2], 'xb') as f:
    f.write(payload)
print('payload bytes:', len(payload))
PY
C100_PAYLOAD_BYTES=$(wc -c < "$C100_BACKUP_DIR/expected-payload.bin" | tr -d ' ')
dfu-util -d 2e3c:df11 -p "$C100_DFU_PATH" -a 0 \
  -s "0x08000000:$C100_PAYLOAD_BYTES" -U "$C100_BACKUP_DIR/readback.bin"
cmp "$C100_BACKUP_DIR/expected-payload.bin" "$C100_BACKUP_DIR/readback.bin"
```

各コマンドが正常終了することを確認してください。`cmp` は一致すれば何も表示しません。不一致や読み出しエラーの場合は、成功と扱わず DFU のまま原因を確認します。

一致後、DFU を終了します。

```sh
dfu-util -d 2e3c:df11 -p "$C100_DFU_PATH" -a 0 -s 0x08000000:leave
```

終了時の USB 切断でエラーに見える表示が出る場合があります。コマンドの表示だけで成功と判断せず、次の通常 USB 接続とプロトコル確認を必ず行ってください。

## 7. 通常接続と入力・LED を確認する

```sh
.build/release/c100-status list
```

ここで表示された通常動作時の `location` を使います。以下の値も例なので置き換えてください。

```sh
C100_LOCATION='0x02110000'  # list で確認した接続位置
.build/release/c100-status companion-info --location "$C100_LOCATION"
```

`layout=10x10`、`input=suppressed`、`keyboard_output=true` を確認します。`keyboard_output=false` は古い拡張なしファームウェアです。新しいイメージを書いたはずなら、イメージと対象を再確認してください。

デーモンが停止した状態で診断します。

```sh
.build/release/c100-status companion-watch 20 --location "$C100_LOCATION"
.build/release/c100-status companion-test 90 --location "$C100_LOCATION"
```

`companion-watch` の間に四隅・中央・連打・同時押しを試し、押下・解放を確認します。`companion-test` は色と明るさのパターンを表示し、最後に 3.3 秒間通信を止めてウォッチドッグを確認します。通常の文字が入力されないこと、消灯することも確認してください。watcher とデーモンは同時に動かせません。

## 8. コンパニオンをインストールする

```sh
scripts/build-app.sh --skip-build
mkdir -p "$HOME/Applications"
ditto '.build/C100 Companion.app' "$HOME/Applications/C100 Companion.app"
"$HOME/Applications/C100 Companion.app/Contents/MacOS/c100-status" config init
```

`config init` は既存設定を上書きしません。既存ファイルがある場合はそれを編集します。設定の `backend` は `companion` にし、必要なら `locationID` に前の手順で確認した位置を指定します。`auto` なら C100 が複数あるときは対象を一意に決められず停止します。プロファイルは自分のマシンの値にします。

```sh
"$HOME/Applications/C100 Companion.app/Contents/MacOS/c100-status" install-agent
open "$HOME/Applications/C100 Companion.app" --args app --layout
"$HOME/Applications/C100 Companion.app/Contents/MacOS/c100-status" inspect
```

`connected: true`、`backend: companion`、`actionTransport: keyboard-hid` を確認します。新方式に root ヘルパーや入力監視の登録は不要です。USB からのアクション送信にはアクセシビリティ権限も不要です。Ghostty のタブ移動を使う場合の Automation 権限は別です。

「サービス」タブで利用サービスを選んで保存し、「レイアウト」でキーを設定します。アクションは前面の有効な対応アプリへ送信します。LED・キー送信が成功したことと、アプリが操作を実行したことは別なので、アーカイブなどは処理してよいタスクで確かめてください。

## 9. 旧 grabber 環境から移行する場合

旧デーモンを停止してから、専用ファームウェアを書き込み、新版アプリと `backend: companion` を設定します。`backend: stock` は新版ではエラーになります。`--companion` は互換オプションとして残りますが、今は指定しなくても専用方式です。

旧 root ヘルパーを導入していたマシンだけ、次を一度実行します。

```sh
sudo "$HOME/Applications/C100 Companion.app/Contents/MacOS/c100-status" uninstall-helper
```

このコマンドは旧 LaunchDaemon・ヘルパーアプリ・旧実行ファイル・ヘルパーログを削除します。ユーザーの設定や Codex データは削除しません。管理者権限が必要なのは、過去に root 所有で設置したものを取り除くこの移行作業だけです。不要になった「C100 Status Grabber」の入力監視登録も macOS の設定から取り除けます。

## 復元・トラブルシューティング

- **DFU が見つからない**：別のデータ対応ケーブルや USB ポートを試し、K00 を押したまま接続する手順をやり直します。
- **書き込み後に通常デバイスとして出ない**：USB を挿し直して確認します。改善しなければ K00 で DFU に戻します。
- **handshake が失敗する**：標準ファームウェアや古いイメージを使っていないか確認します。新版は grabber へ自動的にフォールバックしません。
- **文字入力できない**：専用ファームウェアでは意図した動作です。通常キーボードに戻すにはファームウェアの復元が必要です。
- **LED が消える**：デーモンが通信しなくなると 3 秒で消灯します。`inspect` とログを確認します。

元に戻す場合はデーモンを停止して DFU に入り、対象を再確認します。自分の本体のバックアップを書き戻す例：

```sh
dfu-util -d 2e3c:df11 -p "$C100_DFU_PATH" -a 0 \
  -s 0x08000000 -D "$C100_BACKUP_DIR/original-flash.bin"
dfu-util -d 2e3c:df11 -p "$C100_DFU_PATH" -a 0 \
  -s 0x08000000:262144 -U "$C100_BACKUP_DIR/restored-readback.bin"
cmp "$C100_BACKUP_DIR/original-flash.bin" "$C100_BACKUP_DIR/restored-readback.bin"
dfu-util -d 2e3c:df11 -p "$C100_DFU_PATH" -a 0 -s 0x08000000:leave
```

生のバックアップには DFU suffix がないため、その警告が出る場合があります。書き込みと比較の成否を確認してください。バックアップがない場合の標準キーマップ復元には手順 3 の `keychron_c100_8k_keychron.bin` を使えますが、元の保存設定を戻すものではありません。標準ファームウェアへ戻した後は、現在の C100 Companion デーモンを停止したままにしてください。
