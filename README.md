# Space Groups for Hammerspoon

macOS の Mission Control デスクトップ（Spaces）をグループ化し、メニューバーからの操作・キーボードショートカット・プリセットで効率よく切り替える [Hammerspoon](https://www.hammerspoon.org/) 設定です。

## 機能

- **デスクトップの名前づけ** — 実行時に編集し、`hs.settings` に永続化
- **グループ管理** — 作成・削除・構成変更をメニューから行い、永続化
- **グループジャンプ / グループ内巡回** — 複数デスクトップを順次切り替え（マルチディスプレイ対応）
- **プリセット** — 現在の表示状態（各ディスプレイで表示中のデスクトップ）をスナップショット保存・呼び出し
- **アクティブウィンドウの移動** — メニューから移動先を選択
- **メニューバー表示** — 現在地とグループ内の位置をストリップ表示、クリックで移動
- **ワークスペース状態の一覧表示**

## 必要条件

- macOS（Sequoia 以降でも動作するよう、書き込み系の私有 API は使用していません）
- [Hammerspoon](https://www.hammerspoon.org/) がインストール済みであること

## インストール

1. このリポジトリを `~/.hammerspoon` に配置する（または `init.lua` をコピーする）
2. Hammerspoon を起動し、メニューバーアイコンから **Reload Config** を実行する
3. 初回起動時に「Space Groups loaded」と表示されれば読み込み成功

## macOS の必須設定

以下を設定しないとデスクトップ切り替えが動作しません。

1. **キーボードショートカット → Mission Control**
   - 「デスクトップ1〜9へ切り替え」を有効化する
2. **Mission Control 設定**
   - 「最新の使用状況に基づいて操作スペースを自動的に並べ替える」を **オフ** にする
3. **アクセシビリティ**
   - システム設定で Hammerspoon を許可する

## キーボードショートカット

| ショートカット | 動作 |
|---|---|
| `Ctrl+Alt+1` 〜 `Ctrl+Alt+9` | 対応するグループへジャンプ（グループ数に応じて動的に割り当て） |
| `Ctrl+Alt+→` | 現在のグループ内で次のデスクトップへ |
| `Ctrl+Alt+←` | 現在のグループ内で前のデスクトップへ |
| `Ctrl+Alt+R` | 設定をリロード |
| `Ctrl+Alt+C` | Hammerspoon コンソールを開く |

デスクトップ切り替え自体は macOS 標準の `Ctrl+数字` を合成イベントで発行しています。

## メニューバー

メニューバーアイコンをクリックすると以下の操作ができます。

- **グループ / デスクトップ一覧** — ジャンプ・個別切り替え
- **アクティブウィンドウを移動** — フォーカス中のウィンドウを指定デスクトップへ
- **プリセット管理** — 現在の表示状態の保存・呼び出し・削除
- **グループ管理** — グループの作成・編集・削除、設定からの初期化
- **デスクトップ名を編集** — 表示名の変更、状態一覧
- **ユーティリティ** — `init.lua` を開く、リロード、コンソールなど

メニューバー表示モードは `init.lua` 冒頭の `TITLE_MODE` で変更できます。

- `"full"` — グループアイコン + デスクトップ名 + ストリップ（デフォルト）
- `"compact"` — ストリップのみ

## グループの設定

### 実行時編集（推奨）

メニューバー → **グループ管理** から作成・編集します。変更は `hs.settings` に自動保存されます。

### 初期定義（`DEFAULT_GROUPS`）

`init.lua` 内の `DEFAULT_GROUPS` は **初回起動時のみ** 取り込まれます。以降の編集はメニューから行い、**グループ定義の正は `hs.settings` 側** です。

「グループ管理 → 設定から初期化」で `DEFAULT_GROUPS` の内容に戻せます。

```lua
local DEFAULT_GROUPS = {
  {
    name = "Sound",
    icon = "♪",
    spaces = { {1, "REAPER"}, {2, "Logic"} },
    jump = {4, 1},  -- マルチディスプレイ時: 各ディスプレイ1つずつ、最後の番号にフォーカス
  },
}
```

- `spaces` — `{デスクトップ番号, "表示名（初期値）"}` の配列
- `jump` — ジャンプ時に順次切り替える番号（省略時は先頭番号のみ）

## プリセット

複数ディスプレイで「それぞれどのデスクトップを表示しているか」の組み合わせを保存・復元します。

1. 目的のデスクトップ配置に切り替える
2. メニューバー → **プリセット管理 → 現在の状態を保存…**
3. 名前を付けて保存
4. メニューからプリセット名を選ぶと、保存時と同じ表示状態へ復元される

## ウィンドウ移動の制限

アクティブウィンドウの移動は「タイトルバーをドラッグ保持したまま `Ctrl+数字`」の合成イベント方式です。

- **同一ディスプレイ内のみ** 対応（ディスプレイをまたぐ移動は不可）
- **フルスクリーンウィンドウ** は移動不可
- **デスクトップ10以降** は macOS ショートカット範囲外のため不可

移動がうまくいかない場合は `init.lua` の `DRAG_SETTLE`（デフォルト `0.20` 秒）を `0.3` 程度まで上げて調整してください。

## 設定のカスタマイズ

`init.lua` 冒頭の設定ブロックで変更できます。

| 変数 | 説明 | デフォルト |
|---|---|---|
| `JUMP_MODS` | グループジャンプの修飾キー | `{ "ctrl", "alt" }` |
| `CYCLE_MODS` | グループ内巡回の修飾キー | `{ "ctrl", "alt" }` |
| `CYCLE_NEXT_KEY` / `CYCLE_PREV_KEY` | 巡回方向のキー | `"left"` / `"right"` |
| `TITLE_MODE` | メニューバー表示モード | `"full"` |
| `EDITOR_APP` | 設定ファイルを開くアプリ名（`nil` で関連付けアプリ） | `nil` |
| `DRAG_SETTLE` | ウィンドウ移動時の待ち時間（秒） | `0.20` |
| `SWITCH_FALLBACK` | 順次切り替えの保険タイムアウト（秒） | `0.1` |

## hs.settings

メニューから行った編集（グループ・デスクトップ名・プリセット）は **`init.lua` ではなく `hs.settings`** に保存されます。リポジトリを clone しただけではこれらのデータは引き継がれません。

### 保存場所

macOS の User Defaults（Preferences）に書き込まれます。

```
~/Library/Preferences/org.hammerspoon.Hammerspoon.plist
```

`hs.settings.bundleID` は `org.hammerspoon.Hammerspoon` です。

### 使用しているキー

| キー | 内容 |
|---|---|
| `SpaceGroups.groups` | グループ定義（名前・アイコン・所属デスクトップ・ジャンプ先） |
| `SpaceGroups.nameOverrides` | デスクトップ表示名の上書き |
| `SpaceGroups.presets` | プリセット（表示状態のスナップショット） |

初回起動時、`SpaceGroups.groups` が未設定の場合のみ `init.lua` の `DEFAULT_GROUPS` が取り込まれます。

### 確認・バックアップ

```bash
# キー一覧
defaults read org.hammerspoon.Hammerspoon | grep SpaceGroups

# バックアップ
cp ~/Library/Preferences/org.hammerspoon.Hammerspoon.plist ~/Desktop/hammerspoon-settings-backup.plist
```

Hammerspoon コンソールからも確認できます。

```lua
hs.inspect(hs.settings.get("SpaceGroups.groups"))
hs.inspect(hs.settings.getKeys())
```

### リセット

| 目的 | 方法 |
|---|---|
| グループだけ戻す | メニュー → **グループ管理 → 設定から初期化** |
| 特定キーを削除 | コンソール: `hs.settings.clear("SpaceGroups.groups")` の後リロード |
| Space Groups 関連をすべて削除 | 下記3キーを `hs.settings.clear` する |

```lua
hs.settings.clear("SpaceGroups.groups")
hs.settings.clear("SpaceGroups.nameOverrides")
hs.settings.clear("SpaceGroups.presets")
hs.reload()
```

`.gitignore` の対象外であり、**このリポジトリには含まれません**。別マシンへ移す場合は plist のバックアップか、メニューから再設定してください。

## 技術メモ

- 切り替えの実行系は **`Ctrl+数字` のキーイベント合成のみ** を使用
- `hs.spaces` は読み取り・通知の受信にのみ使用（`moveWindowToSpace` 等の書き込み系 API は使用しない）
- 順次切り替えは `spaces.watcher` + 保険タイマーでイベント駆動
- デスクトップ番号は全ディスプレイを通した連番（`currentSpaceNumber` の走査順）

## トラブルシューティング

| 症状 | 確認事項 |
|---|---|
| デスクトップが切り替わらない | Mission Control の「デスクトップ1〜9へ切り替え」が有効か |
| ジャンプ先がずれる | 「スペースを自動的に並べ替える」がオフか |
| ウィンドウが移動しない | 同一ディスプレイか、フルスクリーンでないか、`DRAG_SETTLE` を調整 |
| ダイアログが出ない | アクセシビリティ権限、Hammerspoon コンソールのエラー出力を確認 |
| 設定変更が反映されない | `Ctrl+Alt+R` でリロード |

## ライセンス

個人利用の Hammerspoon 設定です。必要に応じて自由に改変してください。
