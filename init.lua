-- =========================================================
-- Space Groups for Hammerspoon
-- 統合版：
--   ・デスクトップの名前づけ（実行時編集・永続化）
--   ・グルーピングの実行時編集（作成・削除・構成変更・永続化）
--   ・グループジャンプ／グループ内巡回
--   ・マルチディスプレイ対応（複数デスクトップを順次切り替え）
--   ・イベント駆動による高速順次切り替え（watcher＋保険タイマー）
--   ・プリセット機能（表示状態のスナップショット保存・呼び出し）
--   ・アクティブウィンドウの移動（メニューから移動先を選択）
--   ・ワークスペース状態の取得・一覧表示
--   ・メニューバー表示（現在地＋ストリップ、クリックで移動）
--   ・ユーティリティメニュー
--
-- グループ定義の正は hs.settings（実行時編集分）。
-- 初回起動時のみ下記 DEFAULT_GROUPS から取り込む。
-- 「グループ管理 → 設定から初期化」で DEFAULT_GROUPS に戻せる。
--
-- 切り替えの実行系は Ctrl+数字 のキーイベント合成のみを使用。
-- hs.spaces は読み取り・通知の受信にのみ使用し、書き込み系
-- （moveWindowToSpace 等、Sequoia以降で動作しない私有API）は
-- 使用しない。
--
-- ウィンドウ移動は「タイトルバーをドラッグ保持したまま Ctrl+数字」
-- の合成イベント方式（同一ディスプレイ内のみ・フルスクリーン不可）。
--
-- 必須のOS設定：
--   1. キーボードショートカット → Mission Control で
--      「デスクトップ1〜9へ切り替え」を有効化
--   2. Mission Control 設定で「最新の使用状況に基づいて操作
--      スペースを自動的に並べ替える」をオフ
--   3. アクセシビリティで Hammerspoon を許可
-- =========================================================

-- ---------------------------------------------------------
-- 設定
-- ---------------------------------------------------------

-- グループの初期定義（初回起動時のみ取り込まれる。
-- 以後の編集はメニューから行い hs.settings に保存される）
-- spaces: { {デスクトップ番号, "表示名（初期値）"}, ... }
-- jump:   グループジャンプ時に切り替える番号（ディスプレイごとに1つ）
local DEFAULT_GROUPS = {}

-- キーバインド
local JUMP_MODS      = { "ctrl", "alt" } -- Ctrl+Alt+1〜 でグループジャンプ
local CYCLE_MODS     = { "ctrl", "alt" }
local CYCLE_NEXT_KEY = "left"               -- Ctrl+Alt+N グループ内で次へ
local CYCLE_PREV_KEY = "right"               -- Ctrl+Alt+P グループ内で前へ

-- 順次切り替えの保険タイムアウト（秒）
local SWITCH_FALLBACK = 0.1

-- メニューバー表示モード: "full" / "compact"
local TITLE_MODE = "full"

-- 設定ファイルを開くエディタ。nil なら .lua の関連付けで開く
local EDITOR_APP = nil

local CONFIG_PATH = os.getenv("HOME") .. "/.hammerspoon/init.lua"

-- ウィンドウ移動（ドラッグ合成）の各段の待ち時間（秒）
-- 移動が成立しない場合は 0.3 程度まで上げて調整する
local DRAG_SETTLE = 0.20

-- ---------------------------------------------------------
-- 内部実装
-- ---------------------------------------------------------
local spaces = require("hs.spaces")

-- 前方宣言（後段で定義。相互参照解決のため）
local updateMenubarTitle
local rebindGroupHotkeys

-- ---------------------------------------------------------
-- グループの読み込み・保存
-- 内部形式（settings保存形式と同一）:
--   { { name="Sound", icon="♪",
--       spaces={ {num=1,label="REAPER"}, ... },
--       jump={4,1} }, ... }
-- ---------------------------------------------------------
local GROUPS_KEY = "SpaceGroups.groups"

-- DEFAULT_GROUPS（配列ペア形式）→ 内部形式へ変換
local function convertDefaultGroups()
  local out = {}
  for _, g in ipairs(DEFAULT_GROUPS) do
    local sps = {}
    for _, pair in ipairs(g.spaces) do
      table.insert(sps, { num = pair[1], label = pair[2] })
    end
    table.insert(out, {
      name = g.name, icon = g.icon, spaces = sps,
      jump = g.jump and { table.unpack(g.jump) } or nil,
    })
  end
  return out
end

local GROUPS = hs.settings.get(GROUPS_KEY) or convertDefaultGroups()

local function saveGroups()
  hs.settings.set(GROUPS_KEY, GROUPS)
end
-- 初回はここで永続化される
saveGroups()

-- 番号→初期表示名、番号→(グループindex, グループ内index) の逆引き表。
-- グループ編集のたびに再構築する
local SPACE_NAME, SPACE_GROUP = {}, {}
local function rebuildIndexes()
  SPACE_NAME, SPACE_GROUP = {}, {}
  for gi, g in ipairs(GROUPS) do
    for si, sp in ipairs(g.spaces) do
      if sp.label then SPACE_NAME[sp.num] = sp.label end
      SPACE_GROUP[sp.num] = { gi = gi, si = si }
    end
  end
end
rebuildIndexes()

-- グループ編集後の共通後処理
local function afterGroupsChanged()
  saveGroups()
  rebuildIndexes()
  rebindGroupHotkeys()
  updateMenubarTitle()
end

-- ---------------------------------------------------------
-- Space切り替えの基本操作
-- ---------------------------------------------------------

-- 現在フォーカスのあるデスクトップ番号（全ディスプレイ通し連番）
local function currentSpaceNumber()
  local focused = spaces.focusedSpace()
  local n = 0
  for _, screen in ipairs(hs.screen.allScreens()) do
    local ids = spaces.spacesForScreen(screen)
    if ids then
      for _, id in ipairs(ids) do
        if spaces.spaceType(id) == "user" then
          n = n + 1
          if id == focused then return n end
        end
      end
    end
  end
  return nil
end

-- デスクトップ番号 → Ctrl+数字 のキーイベントを発行して切り替え
local function gotoSpaceNumber(n)
  if n < 1 or n > 9 then
    hs.alert.show("Space " .. n .. " はショートカット範囲外 (1-9)")
    return
  end
  hs.eventtap.keyStroke({ "ctrl" }, tostring(n), 0)
end

-- 複数デスクトップへ順次切り替え（イベント駆動＋保険タイマー）
local seqRunning = false

local function gotoSpacesSequence(numbers)
  if seqRunning then return end
  if #numbers == 0 then return end
  seqRunning = true

  local idx = 0
  local fallbackTimer = nil
  local seqWatcher = nil

  local function cleanup()
    if fallbackTimer then fallbackTimer:stop() end
    if seqWatcher then seqWatcher:stop() end
    seqRunning = false
  end

  local function fireNext()
    if fallbackTimer then fallbackTimer:stop() end
    idx = idx + 1
    if idx > #numbers then
      cleanup()
      return
    end
    gotoSpaceNumber(numbers[idx])
    fallbackTimer = hs.timer.doAfter(SWITCH_FALLBACK, fireNext)
  end

  seqWatcher = spaces.watcher.new(function()
    hs.timer.doAfter(0.05, fireNext)
  end)
  seqWatcher:start()

  fireNext()
end

-- グループジャンプ
local function jumpToGroup(gi)
  local g = GROUPS[gi]
  if not g then return end
  local targets = g.jump
  if not targets or #targets == 0 then
    targets = { g.spaces[1] and g.spaces[1].num }
  end
  if not targets[1] then
    hs.alert.show(g.name .. ": ジャンプ先が未設定")
    return
  end
  gotoSpacesSequence(targets)
  hs.alert.show(g.name, 0.4)
end

-- グループ内巡回
local function cycleInGroup(direction) -- direction: 1 or -1
  local cur = currentSpaceNumber()
  if not cur then
    hs.alert.show("現在のSpaceを特定できません")
    return
  end
  local pos = SPACE_GROUP[cur]
  if not pos then
    hs.alert.show("このSpaceはどのグループにも未登録")
    return
  end
  local g = GROUPS[pos.gi]
  local nextIdx = ((pos.si - 1 + direction) % #g.spaces) + 1
  gotoSpaceNumber(g.spaces[nextIdx].num)
end

-- 設定ファイルを開く
local function openConfig()
  if EDITOR_APP then
    hs.execute(string.format('open -a "%s" "%s"', EDITOR_APP, CONFIG_PATH))
  else
    hs.execute(string.format('open "%s"', CONFIG_PATH))
  end
end

-- ---------------------------------------------------------
-- 入力ポップアップ
-- 一次手段: hs.focus() + hs.dialog.textPrompt
-- 保険:     AppleScript display dialog（エラーはコンソールへ出力）
-- ---------------------------------------------------------
local function asQuoted(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
  return '"' .. s .. '"'
end

local function promptTextViaAppleScript(title, message, defaultValue)
  local script = string.format([[
    set r to display dialog %s with title %s default answer %s ¬
      buttons {"キャンセル", "保存"} default button "保存"
    if button returned of r is "保存" then
      return "OK::" & text returned of r
    else
      return "CANCEL::"
    end if
  ]], asQuoted(message), asQuoted(title), asQuoted(defaultValue))

  local ok, result, rawError = hs.osascript.applescript(script)
  if not ok then
    print("promptText(AppleScript) error: " .. hs.inspect(rawError))
    return nil
  end
  if type(result) == "string" and result:sub(1, 4) == "OK::" then
    return result:sub(5)
  end
  return nil
end

-- 戻り値: 入力文字列 / nil（キャンセル時）
local function promptText(title, message, defaultValue)
  hs.focus()
  local ok, button, text = pcall(hs.dialog.textPrompt,
    title, message, defaultValue or "", "保存", "キャンセル")
  if ok then
    if button == "保存" then return text end
    return nil
  end
  print("promptText: hs.dialog.textPrompt failed, falling back to AppleScript: "
        .. tostring(button))
  return promptTextViaAppleScript(title, message, defaultValue)
end

-- 確認ダイアログ（削除・初期化用）。true=実行
local function confirmDialog(title, message)
  hs.focus()
  local ok, button = pcall(hs.dialog.blockAlert, title, message, "実行", "キャンセル")
  if ok then return button == "実行" end
  print("confirmDialog: hs.dialog.blockAlert failed: " .. tostring(button))
  return false
end

-- "1,2,4" のようなカンマ区切りを番号配列へ。不正要素があれば nil とエラー文字列
local function parseNumberList(s)
  local out = {}
  for token in tostring(s or ""):gmatch("[^,%s]+") do
    local n = tonumber(token)
    if not n or n ~= math.floor(n) or n < 1 then
      return nil, ("不正な番号: " .. token)
    end
    table.insert(out, n)
  end
  if #out == 0 then return nil, "番号が入力されていません" end
  return out
end

-- ---------------------------------------------------------
-- ワークスペース状態の取得と名前編集
-- 名前解決の優先順位: 上書き → グループのラベル → "Desktop N"
-- ---------------------------------------------------------
local NAMES_KEY = "SpaceGroups.nameOverrides"
local nameOverrides = hs.settings.get(NAMES_KEY) or {}

local function saveNameOverrides()
  hs.settings.set(NAMES_KEY, nameOverrides)
end

local function effectiveSpaceName(num)
  local ov = nameOverrides[tostring(num)]
  if ov and ov ~= "" then return ov end
  if SPACE_NAME[num] then return SPACE_NAME[num] end
  return "Desktop " .. num
end

-- 全デスクトップの状態を取得（走査順は currentSpaceNumber と同一）
local function getWorkspaceStates()
  local result = {}
  local active = spaces.activeSpaces() or {}
  local focused = spaces.focusedSpace()
  local n = 0
  for _, screen in ipairs(hs.screen.allScreens()) do
    local ids = spaces.spacesForScreen(screen)
    if ids then
      local activeId = active[screen:getUUID()]
      for _, id in ipairs(ids) do
        if spaces.spaceType(id) == "user" then
          n = n + 1
          table.insert(result, {
            num     = n,
            id      = id,
            screen  = screen:name() or "?",
            visible = (id == activeId),
            focused = (id == focused),
          })
        end
      end
    end
  end
  return result
end

local function renameSpace(num)
  local current = effectiveSpaceName(num)
  local name = promptText(
    "デスクトップ名を編集",
    "Desktop " .. num .. " の表示名\n（空欄で保存するとデフォルトに戻ります）",
    current)
  if name == nil then return end

  if name == "" then
    nameOverrides[tostring(num)] = nil
    hs.alert.show("Desktop " .. num .. ": 名前をリセット", 0.6)
  else
    nameOverrides[tostring(num)] = name
    hs.alert.show("Desktop " .. num .. ": " .. name, 0.6)
  end
  saveNameOverrides()
  updateMenubarTitle()
end

-- 状態一覧（◉=フォーカス ○=表示中 ・=非表示）
local function showWorkspaceStates()
  local lines = {}
  for _, s in ipairs(getWorkspaceStates()) do
    local mark = s.focused and "◉" or (s.visible and "○" or "・")
    table.insert(lines,
      string.format("%s %d: %s  [%s]", mark, s.num, effectiveSpaceName(s.num), s.screen))
  end
  hs.alert.show(table.concat(lines, "\n"), 3)
end

-- ---------------------------------------------------------
-- アクティブウィンドウの移動
-- フォーカス中のウィンドウを「タイトルバーをドラッグ保持したまま
-- Ctrl+数字」の合成イベントで指定デスクトップへ運ぶ。
-- 移動後はそのデスクトップに切り替わった状態で終わる。
-- 制限: 同一ディスプレイ内のみ／フルスクリーン・D10以降は対象外
-- ---------------------------------------------------------
local moveRunning = false

-- デスクトップ番号 → そのデスクトップが属するディスプレイ
-- （走査順は currentSpaceNumber / getWorkspaceStates と同一）
local function screenOfSpaceNumber(targetNum)
  local n = 0
  for _, screen in ipairs(hs.screen.allScreens()) do
    local ids = spaces.spacesForScreen(screen)
    if ids then
      for _, id in ipairs(ids) do
        if spaces.spaceType(id) == "user" then
          n = n + 1
          if n == targetNum then return screen end
        end
      end
    end
  end
  return nil
end

local function moveActiveWindowToSpace(targetNum)
  if moveRunning then return end

  local win = hs.window.frontmostWindow()
  if not win or not win:isStandard() then
    hs.alert.show("移動できるウィンドウがありません")
    return
  end
  if win:isFullScreen() then
    hs.alert.show("フルスクリーンウィンドウは移動できません")
    return
  end

  local cur = currentSpaceNumber()
  if cur == targetNum then
    hs.alert.show("すでに Desktop " .. targetNum .. " にあります")
    return
  end
  if targetNum > 9 then
    hs.alert.show("Desktop " .. targetNum .. " はショートカット範囲外 (1-9)")
    return
  end

  local targetScreen = screenOfSpaceNumber(targetNum)
  if not targetScreen or win:screen():id() ~= targetScreen:id() then
    hs.alert.show("ディスプレイをまたぐ移動には対応していません")
    return
  end

  moveRunning = true
  local types = hs.eventtap.event.types
  local appName = win:application() and win:application():name() or "?"

  win:focus()
  hs.timer.doAfter(DRAG_SETTLE, function()
    -- タイトルバー中央付近を掴む
    local f = win:frame()
    local pt = hs.geometry.point(f.x + f.w / 2, f.y + 10)
    hs.eventtap.event.newMouseEvent(types.leftMouseDown, pt):post()
    hs.timer.doAfter(DRAG_SETTLE, function()
      -- 微小移動でドラッグ状態を成立させる
      local p2 = hs.geometry.point(pt.x + 2, pt.y + 2)
      hs.eventtap.event.newMouseEvent(types.leftMouseDragged, p2):post()
      hs.timer.doAfter(DRAG_SETTLE, function()
        -- 掴んだまま切り替えるとウィンドウが付いてくる
        hs.eventtap.keyStroke({ "ctrl" }, tostring(targetNum), 0)
        hs.timer.doAfter(SWITCH_FALLBACK + DRAG_SETTLE, function()
          hs.eventtap.event.newMouseEvent(types.leftMouseUp, p2):post()
          moveRunning = false
          hs.alert.show(appName .. " → " .. effectiveSpaceName(targetNum), 0.6)
          updateMenubarTitle()
        end)
      end)
    end)
  end)
end

-- ---------------------------------------------------------
-- グループ編集
-- ---------------------------------------------------------

-- 所属デスクトップ一覧を "1,2,4" 形式の文字列へ
local function groupSpacesAsText(g)
  local nums = {}
  for _, sp in ipairs(g.spaces) do table.insert(nums, sp.num) end
  return table.concat(nums, ",")
end

-- 番号配列 → spaces 形式へ（既存ラベルは維持、新規番号はラベルなし）
local function numbersToSpaces(g, numbers)
  local labelByNum = {}
  for _, sp in ipairs(g.spaces) do labelByNum[sp.num] = sp.label end
  local out = {}
  for _, n in ipairs(numbers) do
    table.insert(out, { num = n, label = labelByNum[n] })
  end
  return out
end

local function createGroup()
  local name = promptText("グループを作成", "グループ名を入力", "")
  if name == nil or name == "" then return end

  local spacesText = promptText("グループを作成",
    name .. " に所属させるデスクトップ番号\n（カンマ区切り。例: 1,2,4）", "")
  if spacesText == nil then return end
  local numbers, err = parseNumberList(spacesText)
  if not numbers then
    hs.alert.show(err)
    return
  end

  local jumpText = promptText("グループを作成",
    "ジャンプ時に切り替える番号（ディスプレイごとに1つ、カンマ区切り。\n" ..
    "例: 4,1  ※最後の番号にフォーカスが残る。空欄なら先頭番号のみ）", "")
  if jumpText == nil then return end
  local jump = nil
  if jumpText ~= "" then
    local j, jerr = parseNumberList(jumpText)
    if not j then
      hs.alert.show(jerr)
      return
    end
    jump = j
  end

  local g = { name = name, icon = nil, spaces = {}, jump = jump }
  g.spaces = numbersToSpaces(g, numbers)
  table.insert(GROUPS, g)
  afterGroupsChanged()
  hs.alert.show("グループ作成: " .. name, 0.6)
end

local function renameGroup(gi)
  local g = GROUPS[gi]
  local name = promptText("グループ名を変更", "新しいグループ名", g.name)
  if name == nil or name == "" then return end
  g.name = name
  afterGroupsChanged()
  hs.alert.show("グループ名変更: " .. name, 0.6)
end

local function editGroupIcon(gi)
  local g = GROUPS[gi]
  local icon = promptText("アイコンを変更",
    g.name .. " のアイコン（1文字程度。空欄でアイコンなし）", g.icon or "")
  if icon == nil then return end
  g.icon = (icon ~= "") and icon or nil
  afterGroupsChanged()
end

local function editGroupSpaces(gi)
  local g = GROUPS[gi]
  local text = promptText("所属デスクトップを編集",
    g.name .. " に所属させるデスクトップ番号\n（カンマ区切り。例: 1,2,4）",
    groupSpacesAsText(g))
  if text == nil then return end
  local numbers, err = parseNumberList(text)
  if not numbers then
    hs.alert.show(err)
    return
  end
  g.spaces = numbersToSpaces(g, numbers)
  afterGroupsChanged()
  hs.alert.show(g.name .. ": 構成を更新", 0.6)
end

local function editGroupJump(gi)
  local g = GROUPS[gi]
  local currentJump = g.jump and table.concat(g.jump, ",") or ""
  local text = promptText("ジャンプ先を編集",
    g.name .. " のジャンプ時に切り替える番号\n" ..
    "（ディスプレイごとに1つ、カンマ区切り。最後の番号にフォーカスが残る。\n" ..
    "空欄で保存すると先頭番号のみになります）",
    currentJump)
  if text == nil then return end
  if text == "" then
    g.jump = nil
  else
    local j, err = parseNumberList(text)
    if not j then
      hs.alert.show(err)
      return
    end
    g.jump = j
  end
  afterGroupsChanged()
  hs.alert.show(g.name .. ": ジャンプ先を更新", 0.6)
end

local function deleteGroup(gi)
  local g = GROUPS[gi]
  if not confirmDialog("グループを削除",
      "「" .. g.name .. "」を削除します。よろしいですか？\n" ..
      "（デスクトップ自体やプリセットは削除されません）") then
    return
  end
  local name = g.name
  table.remove(GROUPS, gi)
  afterGroupsChanged()
  hs.alert.show("グループ削除: " .. name, 0.6)
end

local function resetGroupsToDefault()
  if not confirmDialog("グループを初期化",
      "全グループを init.lua の DEFAULT_GROUPS の内容に戻します。\n" ..
      "実行時の編集内容は失われます。よろしいですか？") then
    return
  end
  GROUPS = convertDefaultGroups()
  afterGroupsChanged()
  hs.alert.show("グループを初期化しました", 0.6)
end

-- ---------------------------------------------------------
-- プリセット（スナップショット）機能
-- ---------------------------------------------------------
local PRESETS_KEY = "SpaceGroups.presets"
local presets = hs.settings.get(PRESETS_KEY) or {}

local function savePresetsToDisk()
  hs.settings.set(PRESETS_KEY, presets)
end

local function currentVisibleSpaceNumbers()
  local visible = {}
  local focusedNum = nil
  for _, s in ipairs(getWorkspaceStates()) do
    if s.visible then
      if s.focused then
        focusedNum = s.num
      else
        table.insert(visible, s.num)
      end
    end
  end
  if focusedNum then table.insert(visible, focusedNum) end
  if #visible == 0 then return nil end
  return visible
end

local function saveCurrentAsPreset()
  local targets = currentVisibleSpaceNumbers()
  if not targets then
    hs.alert.show("現在の表示状態を取得できません")
    return
  end
  local name = promptText(
    "プリセットを保存",
    "現在の表示: Desktop " .. table.concat(targets, ", ") ..
      "\n（最後の番号にフォーカスが復元されます）",
    "")
  if name == nil or name == "" then return end

  for _, p in ipairs(presets) do
    if p.name == name then
      p.targets = targets
      savePresetsToDisk()
      hs.alert.show("プリセット更新: " .. name, 0.6)
      return
    end
  end
  table.insert(presets, { name = name, targets = targets })
  savePresetsToDisk()
  hs.alert.show("プリセット保存: " .. name, 0.6)
end

local function recallPreset(p)
  gotoSpacesSequence(p.targets)
  hs.alert.show(p.name, 0.4)
end

local function deletePreset(index)
  local name = presets[index] and presets[index].name or "?"
  table.remove(presets, index)
  savePresetsToDisk()
  hs.alert.show("プリセット削除: " .. name, 0.6)
end

-- ---------------------------------------------------------
-- メニューバー
-- ---------------------------------------------------------
local menubar = hs.menubar.new()

local function buildStrip(cur)
  local parts = {}
  for _, g in ipairs(GROUPS) do
    local s = ""
    for _, sp in ipairs(g.spaces) do
      s = s .. (sp.num == cur and "●" or "○")
    end
    table.insert(parts, s)
  end
  return table.concat(parts, " ")
end

-- 前方宣言済み。ここで定義を代入する
function updateMenubarTitle()
  local cur = currentSpaceNumber()
  if not cur then
    menubar:setTitle("Spaces: ?")
    return
  end
  local strip = buildStrip(cur)
  if TITLE_MODE == "compact" then
    menubar:setTitle(strip)
    return
  end
  local pos = SPACE_GROUP[cur]
  if pos then
    local g = GROUPS[pos.gi]
    menubar:setTitle((g.icon or "") .. " " .. effectiveSpaceName(cur) .. " │ " .. strip)
  else
    menubar:setTitle("D" .. cur .. " │ " .. strip)
  end
end

-- メニュー構築
local function buildMenu()
  local items = {}
  local cur = currentSpaceNumber()

  -- グループ／デスクトップ一覧（平置き）
  for gi, g in ipairs(GROUPS) do
    table.insert(items, {
      title = (g.icon or "") .. " " .. g.name,
      fn = function() jumpToGroup(gi) end,
    })
    for _, sp in ipairs(g.spaces) do
      local num = sp.num
      table.insert(items, {
        title = "    " .. num .. ": " .. effectiveSpaceName(num),
        checked = (num == cur),
        fn = function() gotoSpaceNumber(num) end,
      })
    end
    if gi < #GROUPS then table.insert(items, { title = "-" }) end
  end
  if #GROUPS == 0 then
    table.insert(items, { title = "（グループなし）", disabled = true })
  end

  -- アクティブウィンドウの移動
  -- ディスプレイをまたぐ移動には未対応のため、移動先は現在フォーカス中の
  -- デスクトップと同一ディスプレイのものだけに限定する
  table.insert(items, { title = "-" })
  local moveSub = {}
  local states = getWorkspaceStates()
  local focusedScreen = nil
  for _, s in ipairs(states) do
    if s.focused then focusedScreen = s.screen end
  end
  for _, s in ipairs(states) do
    if s.screen == focusedScreen then
      local num = s.num
      table.insert(moveSub, {
        title = num .. ": " .. effectiveSpaceName(num) .. "  [" .. s.screen .. "]",
        disabled = s.focused,  -- 現在地への移動は無意味なので無効化
        fn = function() moveActiveWindowToSpace(num) end,
      })
    end
  end
  if #moveSub == 0 then
    table.insert(moveSub, { title = "（移動先なし）", disabled = true })
  end
  table.insert(items, { title = "アクティブウィンドウを移動", menu = moveSub })

  -- プリセットセクション
  table.insert(items, { title = "-" })
  if #presets > 0 then
    for _, p in ipairs(presets) do
      local pp = p
      table.insert(items, {
        title = "★ " .. pp.name,
        fn = function() recallPreset(pp) end,
      })
    end
  else
    table.insert(items, { title = "（プリセットなし）", disabled = true })
  end

  local manageSub = {
    { title = "現在の状態を保存…", fn = saveCurrentAsPreset },
  }
  if #presets > 0 then
    table.insert(manageSub, { title = "-" })
    for i, p in ipairs(presets) do
      local idx, name = i, p.name
      table.insert(manageSub, {
        title = "削除: " .. name,
        fn = function() deletePreset(idx) end,
      })
    end
  end
  table.insert(items, { title = "プリセット管理", menu = manageSub })

  -- グループ管理
  table.insert(items, { title = "-" })
  local groupSub = {
    { title = "新規グループを作成…", fn = createGroup },
    { title = "-" },
  }
  for gi, g in ipairs(GROUPS) do
    local i = gi
    table.insert(groupSub, {
      title = (g.icon or "") .. " " .. g.name ..
              "  [" .. groupSpacesAsText(g) .. "]",
      menu = {
        { title = "名前を変更…", fn = function() renameGroup(i) end },
        { title = "アイコンを変更…", fn = function() editGroupIcon(i) end },
        { title = "所属デスクトップを編集…", fn = function() editGroupSpaces(i) end },
        { title = "ジャンプ先を編集…", fn = function() editGroupJump(i) end },
        { title = "-" },
        { title = "このグループを削除…", fn = function() deleteGroup(i) end },
      },
    })
  end
  table.insert(groupSub, { title = "-" })
  table.insert(groupSub, { title = "設定から初期化…", fn = resetGroupsToDefault })
  table.insert(items, { title = "グループ管理", menu = groupSub })

  -- デスクトップ名の編集
  local renameSub = {
    { title = "状態を一覧表示", fn = showWorkspaceStates },
    { title = "-" },
  }
  for _, s in ipairs(getWorkspaceStates()) do
    local num = s.num
    local suffix = nameOverrides[tostring(num)] and " ✎" or ""
    table.insert(renameSub, {
      title = num .. ": " .. effectiveSpaceName(num) ..
              "  [" .. s.screen .. "]" .. suffix,
      checked = s.focused,
      fn = function() renameSpace(num) end,
    })
  end
  table.insert(items, { title = "デスクトップ名を編集", menu = renameSub })

  -- ユーティリティ
  table.insert(items, { title = "-" })
  table.insert(items, {
    title = "ユーティリティ",
    menu = {
      { title = "設定を開く (init.lua)", fn = openConfig },
      { title = "設定をリロード", fn = function() hs.reload() end },
      { title = "-" },
      { title = "コンソールを開く", fn = function() hs.openConsole() end },
      { title = "Hammerspoon環境設定を開く", fn = function() hs.openPreferences() end },
    },
  })

  return items
end

menubar:setMenu(buildMenu)

-- ---------------------------------------------------------
-- Space切り替え検知 → メニューバー更新
-- ---------------------------------------------------------
local spaceWatcher = spaces.watcher.new(function()
  hs.timer.doAfter(0.3, updateMenubarTitle)
end)
spaceWatcher:start()

-- watcherの動作を実機確認できたらこの行は削除してよい
local pollTimer = hs.timer.doEvery(2, updateMenubarTitle)

-- ---------------------------------------------------------
-- キーバインド
-- グループジャンプはグループ数の増減に追従するため動的に再登録する
-- ---------------------------------------------------------
local groupHotkeys = {}

-- 前方宣言済み。ここで定義を代入する
function rebindGroupHotkeys()
  for _, hk in ipairs(groupHotkeys) do hk:delete() end
  groupHotkeys = {}
  for gi = 1, math.min(#GROUPS, 9) do
    local i = gi
    table.insert(groupHotkeys,
      hs.hotkey.bind(JUMP_MODS, tostring(gi), function() jumpToGroup(i) end))
  end
end
rebindGroupHotkeys()

hs.hotkey.bind(CYCLE_MODS, CYCLE_NEXT_KEY, function() cycleInGroup(1) end)
hs.hotkey.bind(CYCLE_MODS, CYCLE_PREV_KEY, function() cycleInGroup(-1) end)
hs.hotkey.bind({ "ctrl", "alt" }, "r", function() hs.reload() end)
hs.hotkey.bind({ "ctrl", "alt" }, "c", function() hs.openConsole() end)

-- ---------------------------------------------------------
-- 起動
-- ---------------------------------------------------------
updateMenubarTitle()
hs.alert.show("Space Groups loaded", 0.6)