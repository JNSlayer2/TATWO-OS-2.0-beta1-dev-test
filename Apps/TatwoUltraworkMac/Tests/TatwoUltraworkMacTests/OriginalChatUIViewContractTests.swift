import Foundation
import XCTest

final class OriginalChatUIViewContractTests: XCTestCase {
    // 2026-07-22 R21 重封：加入中斷佇列、即時工作條與可伸縮 composer。
    // 2026-07-27 重封：CLI 分頁 loops 進行中列、標題呼吸光暈、停止鍵二次確認。
    //   ChatPage 內只有接線（loopsActivity 觀察者、cliSidebar 插入 strip、
    //   cliTerminalPane 標題列加 glow modifier、composerStopButton 過閘、
    //   onAppear/onDisappear attach/detach），新邏輯全在新檔案。
    //   注意：此封印變更代表「原始 chat UI 已被改動」，工程測試綠不等於 UI 驗收，
    //   仍需主導快照 + 使用者親驗。
    // 2026-07-27 重封（整合階段）：CLI 終端窗格改走 PTY 真終端。
    //   ChatPage 內僅接線：cliTerminals 型別改為 TatwoCLITerminalHandle、
    //   新增 activeCLITabPTYSession 存取器、終端窗格在 PTY 後端下改用 NativeTerminalPTYView，
    //   pipe fallback 維持原本的唯讀 ScrollView 分支。
    //   同前：封印變更代表原始 chat UI 已被改動，工程測試綠不等於 UI 驗收。
    // 2026-07-27 重封（CLI shell 收尾）：容器關閉的 stop handler 從 model.stop()
    //   改為 model.shutdownForContainerClose()，多收 CLI 分頁的 PTY／pipe session。
    //   封印區內只有這一行變動；其餘收尾邏輯都在 ChatPageModel（封印區外）。
    // 2026-07-27 重封（浮動光幾何重做）：光暈 modifier 從滿寬 HStack 移到標題 Label 上，
    //   讓它只包住 icon＋標題文字。右側 running 徽章與 tab 樣式未動。
    // 2026-07-27 重封（icon tint）：標題 Label 改用 icon/title 兩段式，
    //   只為了讓終端 icon 在算力共享中時能單獨上暖色 tint。
    //   字色、右側 running 徽章、tab 樣式皆未動。
    // 2026-07-28 重封（CLI 左列 session 樹）：cliSidebar 改接 CLISessionTree，
    //   mainPane 在 selectedCLILoopID 時顯示 CLILoopDetailPane；新邏輯在新檔，
    //   ChatPage 只做最小接線。工程綠≠UI 驗收。
    // 2026-07-28 重封（Wave1 UI declutter）：移除 ChatRunMode.cowork 分頁與 coworkSidebar
    //   接線；beginCowork/queue/timer 執行機制一併清除；協作改 loops-config only。工程綠≠UI 驗收。
    // 2026-07-31 UO1 重封：只把舊 Opus 路由字串改為 opus-5；
    //   無視覺排版、控制結構或互動行為變更。
    // 2026-07-31 Chat 動態重封：移除 composer 上方「即時／最近工作」方框與
    //   composer 下方重複工作狀態；工作動態只留在 transcript 的呼吸文字。
    //   暫停的插話佇列改為工具列精簡繼續控制。已先完成 1220×980 candidate 快照自驗。
    // 2026-07-31 遠端借用接線重封：ChatPage 的 model ownership 上提到
    //   TatwoPanelView，讓 Chat／Devices 共用同一個主 Session；ChatPage 只由
    //   StateObject 改為接收 ObservedObject，未改 body 排版。工程綠仍不等於 UI 終驗。
    // 2026-07-31 Codex-style transcript 重封：依使用者要求移除 composer 上方
    //   中央 Goal 方框；Goal/Plan 仍保留在右側 Thread。工作狀態只在 transcript
    //   以文字動態呈現。此 hash 只封 source 變更，仍須同輪 Codex baseline 視覺終驗。
    // 2026-08-02 高強度辦公重封：模型切換在當前回合執行中時顯示「下一輪」pending
    //   狀態，picker 標題使用實際／待切模型標籤；Haiku exact route 固定為 4.5。
    //   Loops 右欄同輪加入寬版／全寬工作區、可還原封存及 human 規劃筆記接線；
    //   檔案瀏覽改讀當前 conversation workspace。這些都是使用者可見變更，
    //   工程 hash 通過仍不等於 Codex baseline 視覺終驗。
    // 2026-08-04 重封：逐 hunk 核對上述 7/31–8/2 使用者已要求的變更後更新 hash；
    //   未把未審差異混入允許清單。仍需單一 staging App 的真人視覺終驗。
    // 2026-08-05 重封：獨立副審再次逐項核對 Codex-style inline transcript、
    //   Loops workspace 與共享主 Session 接線；只更新 source seal，不取代真人 UI 驗收。
    // 2026-08-07 可見閒置狀態重封：輸入框下方抽屜常駐顯示「無額外提醒」與中性圓點，
    //   minHeight 30 並強化淺／深色辨識；只重封 source，不代表 installed visual 終驗。
    // 2026-08-07 typed footer projector 重封：抽屜只讀五態 projector，
    //   ordinary Chat／CLI hard gate 為 neutral；不讀 hint、長狀態字串或 inline activity。
    // Re-sealed after ChatPage god-file split (76ae1f2): View body still lives in
    // ChatPage.swift; digest tracks that file only from `struct ChatPage: View`.
    // 2026-08-13 PLG 收斂重封（fable-5 主導逐 hunk 審核，contract-l-coding-fe9c2f9e8ecb）：
    //   17 個 hunk 全屬 7/31–8/7 已封存方向的延續——Loops 全寬工作區＋takeover header、
    //   移除 composer 上方 Goal 方框、typed footer 五態抽屜收斂、transcript 內嵌
    //   ChatInlineWorkTimelineView（工作動態新家）、模型切換「下一輪」pending 圖示、
    //   協作 picker 標籤、haiku-4-5 版號修正。無未核准新表面。
    //   只重封 source；installed App 真人視覺終驗仍待使用者（recovery-20260813 步 3 三題）。
    // 2026-08-13 UI 修整輪重封（fable-5 逐 hunk 審核；使用者當日實機驗收指示）：
    //   FIX1 composerStatusBar 黏合回輸入框下緣（-13 tuck + zIndex(-1)，配對 +13 上緣留白）；
    //   FIX3 討論串去刪除線改 dim＋狀態小點，繼承快照/收工摘要收合為展開器（機制不動）。
    //   diff 對 dd7c856 逐行審過無夾帶。真人視覺終驗仍待使用者看快照/實機。
    // 2026-08-13 UI 修整輪2重封（fable-5 逐行審核；使用者第二輪實機裁定五項）：
    //   全中文選單「把結論併回主線」、收工摘要白話化（presentation-only humanizer）、
    //   tab ✕ 必關（真兇：chip 整體 onTapGesture 吃掉 ✕，改分離 Button＋正確 terminate）、
    //   ＋直開 Shell 終端（撤引擎子選單）、＋移左列＋CLI 模式整個 composer 不掛載。
    //   真人視覺終驗待使用者第三輪實機。
    // 2026-08-13 UI 修整輪3重封（fable-5 審核；使用者第三輪實機三項）：
    //   ✕ 三層真因全修——book.close 經 wrapper 不觸發 @Published（整本 assign 回）、
    //   prepareCLITabs 空時自動再開（撤）、橫向 ScrollView 吃小 Button click（改 highPriorityGesture）；
    //   啟動鈕 running 時隱藏；左列終端籤列出開啟 session（點選/hover ✕ 關閉）。
    // 2026-08-14 CLI 暗沉重封（fable-5 快照親驗）：composer 卸載後 tab+標題列坐在
    //   外層霜化空帶讀成灰霧；玻璃面改包整卡＋視窗模式補 32pt titlebar 讓位。
    // 2026-08-14 CLI 暗沉第二輪重封（fable-5 審核）：32pt titlebar 讓位帶露出視窗底材
    //   為真兇；canvas 補覆蓋該帶＋終端字體對齊 app mono 尺寸＋內距 10-12pt。
    // 2026-08-14 CLI 第三輪重封：r2 全幅 GlassCard 吃掉 Chat 對稱橫向 gutter；
    //   外層改回 transcript 18pt + mainPane contentMaxWidth 置中，titlebar canvas 覆蓋保留。
    // 2026-08-15 島殼收割重封（fable-5 逐 hunk 審核；使用者 MacBook 輪收工收割）：
    //   TatwoIslandShell 新功能接線＋issue「帶入聊天」鈕抽取復用於 focused 視圖。
    // 2026-08-17 TATWO OS 自主開發 E2E 重封：Chat 模式在無側欄時保留可見的
    //   OS 設定入口，送出鈕補 Computer Use 可定位的 accessibility identifier/action。
    //   這只更新 source seal；仍需單一 staging App 的真人視覺與互動終驗。
    // 2026-08-19 PLG 原生執行接線重封：確認計畫按鈕由只推進 planning
    //   改為同一按鈕確認計畫並啟動受 contract 約束的 loops；外觀、布局與標籤未改。
    //   這只重封 source；仍需單一 staging App 的真人互動終驗。
    // 2026-08-20 M2b devModeToggleChip 已依使用者裁決移除（「不需要特地點
    //   一個開發鈕」）：開發能力改為預設常開、由權限檔位管制（D2 修訂）。
    //   ChatPage 位元組回到 chip 之前原狀，封印還原原值。
    // 2026-08-20 M4b cycle 人門接線：LoopsSessionRail 呼叫點加傳
    //   plgCanAdvanceCycle / onPLGAdvanceCycle 兩參數（開新 cycle 按鈕在
    //   PLGFlowCard，ChatPage 僅 wiring 兩行）；外觀與布局未改。
    //   這只重封 source；仍需 staging 真人終驗。
    // 2026-08-20 M5FIX-r2 重封：ChatPage 只註冊／解除註冊「新聊天」
    //   command handler，讓 AppShell 的 Cmd-N／Cmd-Shift-O 呼叫 model.newChat()。
    //   未新增或調整任何 View、modifier、布局、主題或可見控制項。
    // 2026-08-20 極光 P5 重封（使用者授權第二階段主題隔離）：停止鈕語意色
    //   theme-branch——極光改 systemRed（紫色無中止語意＝fable5 決策污染），
    //   fable5 維持 brandAccent 赤陶一位元不動；chrome 結構未改。
    // 2026-08-20 極光 P4 材質收編重封：兩個裸材質膠囊
    //   （.regularMaterial/.thinMaterial in Capsule）改走 tatwoAdaptiveCapsule
    //   token——極光外觀等值、fable5 得到暖紙分支；無布局變更。
    // 2026-08-20 主題縮影重封（使用者裁決「UI 是優先語言」）：主題選擇器
    //   的色條 pill 升級為主題縮影卡（canvasBase 底＋氛圍漸變＋迷你面卡
    //   ＋選中 brandAccent 外環）——用設計語言展示主題本身；文字列保留。
    // 2026-08-20 極光實機驗收輪重封（使用者六圖五項回饋）：①左下互斥——
    //   OS 選單開啟時隱藏底下字標與 hover rail（雙字標/三層疊修復）；
    //   ②抽屜極光分支改直邊＋玻璃霜面（灰梯形退役，fable5 原樣）；
    //   ③rail 貼邊圓角 34→16（與視窗圓角打架）。chip 提亮在 modifiers 檔。
    // 2026-08-20 驗收輪二重封（使用者裁決回歸）：一體化撤回、獨立梯形
    //   抽屜保留；極光只換皮＝梯形穿玻璃（霜面＋白紗 0.22＋主題白描邊，
    //   斜邊照舊），fable5 灰梯形原樣。
    // 2026-08-20 使用者調參重封：梯形太透→補 ultraworkGradient 身份
    //   漸變（identity×1.6）、白紗降 0.12；形狀機制不變。
    // 2026-08-21 composerHint 顯示層重建重封：閉環驗收抓到 composerHint
    //   全 app 零渲染點——幾十處 flashComposerHint（/goal //plg 失敗原因
    //   在內）全數無處可顯＝「靜默丟棄」顯示層真兇。hint 借道既有抽屜
    //   狀態列顯示（brandAccent 圓點＋semibold），無新形狀、布局不變。
    // 2026-08-21 任務二批次重封（使用者指示）：①/plan 計劃書畫布
    //   planArtifactCanvas（codex 同款：卡＋展開全文＋一鍵複製＋確認，
    //   釘輸入框上方）；②右鍵新增「複製對話串 ID」；③左下角可點 TATWO
    //   OS 字標移除（使用者裁決，入口只留 sidebar 那份）；④側欄
    //   maxHeight 天地齊平。
    // 2026-08-21 計劃書畫布重設計重封（使用者「計劃書好醜」）：文件隱喻
    //   ——漸變書脊＋方章 icon＋高度貼合內容（空 sections 一行提示，不再
    //   撐空箱）＋段落編號排版＋漸變確認鈕；a11y 識別碼與行為 API 不變。
    //   r2：書脊改 overlay——Shape 當 HStack 子元素會貪婪撐滿可用高，
    //   首版卡片下方因此多出一大片空玻璃（實機抓到）。
    // 2026-08-21 v3 使用者裁決重封：極光＝液態玻璃＋ultrawork 漸變（抽屜
    //   定案配方）；fable5 依自己風格＝暖紙實底＋暖褐邊＋赤陶書脊，不沾
    //   紫藍粉；複製鈕改純符號圓 chip。a11y 識別碼不變。
    //   調參：使用者「沒看到變化」→漸變 identity×1.45、白紗 0.06、描邊 0.7。
    // 2026-08-21 v4 重封（使用者三項＋新功能）：①左側書脊移除；②確認改
    //   純圓鈕打勾無文字（編輯中隱藏防誤確認）；③複製符號換 square.on.
    //   square；④新增鉛筆↔儲存鈕＝畫布內直接編輯計劃書（TextEditor，
    //   存回走 applyEditedText 解析，內容修改退回 discussing）。
    //   v4.1 調參：三顆圓鈕縮小（chip 24pt／確認 26pt），儲存符號改打勾。
    //   v4.2：確認回饋強化——彈跳動效＋已確認圖示 transition（磁碟證實
    //   確認一直有執行，是回饋太弱讓使用者以為沒反應）。
    //   v5 使用者裁決：畫布確認＝人門，按下自動切進 PLG（help 文案改）。
    // 2026-08-21 v6 互動定案重封：執行入口移到 composer——計劃書就緒時
    //   打勾徽章浮在單模型／ultrawork 控制項頭上（點擊前可換模型，點擊
    //   後依配置執行：ultrawork＝PLG／單模型＝goal）；畫布確認圓鈕退役
    //   （單一入口），已確認狀態圖示保留。
    // 2026-08-22 Gen-4 授權重封（使用者 /goal「開工 gen4 ui」＋GEN4_UI_PLAN §1-8）：
    //   ChatRunMode 加 .bot 第三格；sidebar/.bot 讓位 EmptyView；mainPane
    //   加 .bot 分支導向 BotPageRootView（零副作用）；composer 於 .bot 不掛接；
    //   botExportScene export-only helper。Chat/CLI 原路徑零改動。
    // 2026-08-22（二）：使用者「底下短一截、對齊最底部」——.bot 分支加
    //   -18pt 底 padding 抵銷 retainedWindowPage；仍僅 .bot 路徑，Chat/CLI 零改動。
    // 2026-08-23 修「bot 分頁切不回」重封：.bot 分支傳 onSwitchMode 回呼（同正式分支修復）。
    // 2026-08-23 三分頁一致化＋CLI 大改重封（使用者七項指示）：①側欄固定 250、
    //   三模式一律 overlay 不佔版寬（切換不再跳動，高度以 bot 為標準）；②cli 持久
    //   側欄退役、併入 hover rail（rail 依模式host cliSidebar/chatSidebar）；③rail
    //   常駐改 AppStorage 三頁共用＋Dia 收合鈕（左上 sidebar.left chip）；④rail 底
    //   對齊 -18；⑤終端卡 GlassCard→CLISolidCard 實底（灰霧根治）＋高上限 460 橫向
    //   長方；⑥終端標頭加專注/分離小視窗功能鈕；⑦bot 模式 reserves=0。
    // 2026-08-23 sol 一致性收尾 R2：①常駐狀態同步紅綠燈與 pin 位置；
    // ②pinned 250pt 推寬、hover 僅未 pinned；③三頁模式膠囊 54/30/4/12；
    // ④CLI 右上多卡 300/600、每卡獨立 PTY/關閉/專注/分離；⑤CLI loops 路由退出。
    // 2026-08-23 R3 重封（fable5 親修）：Dia 原樣常駐鈕（白底圓角方塊細邊框，
    //   去玻璃膠囊/去品牌色）＋CLI 左列扁平化靠左（拆雙層填色盒/去副標/工具鈕改
    //   純圖示/單段 segment 隱藏）＋樹點 session 改開終端分頁卡（舊 single-terminal
    //   殭屍路徑退役：不再覆寫 selectedProjectID/workspacePath、不再隱形 spawn——
    //   「chat 匯入專案點擊後切分頁失效」頭號嫌犯移除）。
    // 2026-08-23 R4 重封（使用者截圖四項＋落地）：分頁列上移 54→36；「工作區/CLI
    //   Sessions」標題移除（工具移掛分頁列）；搜尋縮小 28pt 同分頁列寬；常駐鈕
    //   移左列右上角（三分頁同位）；常駐持久側欄槽位補 -18 落地對齊 app 底。
    // 2026-08-22 engineering D re-seal: the only ChatPage delta is the
    // App-management MCP notification receiver that switches Chat/CLI mode.
    // 2026-08-23 重封：工程 B 一鍵授權——ChatPage 加 .tatwoChatAllowMCPTool
    // onReceive（MCP 權限請求訊息的「允許此工具」鈕→per-thread allowlist）。
    // 2026-08-24 C-seg1 刀2 重封：TranscriptScrollView 的 displayItems 改 fingerprint
    // memoize；onChange 不再深比較整份 messages。布局與可見控制項未改。
    // 2026-08-24 Bug4 重封：ChatTranscriptDisplayFingerprint 從 ChatPage 移到
    // ChatPageModels（每列 mix text hash / modelID / planQuestions.count）。
    // ChatPage 只保留 fingerprint 呼叫點；布局與可見控制項未改。
    // 2026-08-26 /plan Codex parity 重封：舊 composer-pinned 計劃畫布退役；
    // Plan 改為 transcript item（Writing plan → Plan），支援側邊 inspector。
    // 使用者後續明確拍板：Plan inspector 必須接回 TATWO OS 生態，
    // 顯示 /goal、/plg 與單模型／多模型選擇；本輪先完成 UI，不直接派工。
    // 2026-08-26 /plan composer-focus 修復只改 clarification card 的
    // focus-scoped key handling；ChatPage 核准面維持上述 /plan parity 封印。
    // 2026-08-26 /plan turn-anchor 修復：完成的 Plan transcript item 改綁
    // 真正產生它的 assistant message；新 Plan turn 即使已有舊 artifact，
    // 仍顯示 Writing plan。只重封這兩個已核准的 parity 修正。
    // 2026-08-26 /plan UX 收尾重封：右側 Plan 加鉛筆／打勾人工編輯，
    // 接續卡改 /goal、/plg、單模型、Ultrawork 與明確執行鈕；Ultrawork
    // 在 Plan inspector 原地切換既有面板，下方角色格依 S/M/L/XL/XXL 顯示主1＋輔0...4，
    // 並沿用單模型品牌目錄。此次只優化 Plan 表面，未重設 Goal/PLG。
    // 2026-08-26 使用者再次核准 Plan 內嵌 Ultrawork 面板收尾：
    // 移除「通用 · 模型主導」情境列，團隊摘要與主／輔選模改為
    // 可換行的較大字級網格；不改回滿版，也不延伸到 Goal／PLG。
    // 2026-08-26 Plan Ultrawork 互動收尾：模式只由滑桿標示；
    // 放開滑桿立即更新團隊；獨立主／輔選模列退役，改點團隊 chip
    // 在 Plan 畫布原地開既有模型目錄。
    // 2026-08-27 /plan Goal Judge 閉環重封：單模型 runner 完成後，
    // 既有 activeGoalInlineCard 接回 composer 上方。completed cycle 會寫入
    // 可回查 receipts 並觸發 Goal Judge；不得用假 receipt count 或硬設 passed。
    // 2026-08-28 使用者實機回歸裁定：Chat/CLI 結構側欄恢復貼齊 App 天地，
    // 撤除 retained page 全域 18pt 底縮短與 -18pt 補丁；18pt 僅保留在
    // Chat composer 內容 gutter。Loops/Bot 同輪由各自 source contract 封印。
    // 2026-08-29 瀏覽器 session 隔離接線重封：EmbeddedBrowserView 只新增
    // selectedThreadID 作為 sessionID；Chat 排版、Plan、思考中與 transcript
    // 呈現未改。source seal 不取代同版 staging 的 Computer Use 視覺終驗。
    // 2026-08-29 transcript render-key 效能重封：scroll destination 改從
    // model-stamped O(1) display fingerprint 讀 assistant ID／Plan 問題狀態，
    // 不再重掃 messages；沒有新增或改動可見排版、控制項與 timeline 呈現。
    // 2026-08-29 Plan 思考收納重封：transcript builder 的 cache miss／refresh
    // 與 history minimap 統一讀 presentation-only projectedMessages；投影只鎖定
    // Plan artifact（或 Writing plan）的 assistant row，並把確認後送交 Work OS
    // 的 execution envelope 收成既有「思考中」timeline。canonical transcript、
    // Plan artifact、layout 與控制項不變；這是本 Goal 明確要求的防洗版呈現。
    // 2026-08-13 使用者指示全中文
    private let permittedDiscussionMergeMenuAction = """
                Button {
                    model.selectDiscussion(projectID: project.id, threadID: thread.id, discussionID: discussion.id)
                    model.mergeDiscussionIntoParent(discussion.id)
                } label: { Label("把結論併回主線", systemImage: "arrow.triangle.merge") }

"""

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try ChatSourceFamily.read(url: repoRoot.appendingPathComponent(relativePath))
    }

    private func orderedRange(
        _ needle: String,
        in source: String,
        after lowerBound: String.Index? = nil
    ) throws -> Range<String.Index> {
        let searchRange = (lowerBound ?? source.startIndex)..<source.endIndex
        return try XCTUnwrap(source.range(of: needle, range: searchRange))
    }

    func testChatKeepsTargetedOriginalInteractionContracts() throws {
        let chatPage = try source(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPage.swift")
        let start = try XCTUnwrap(
            chatPage.range(of: "struct ChatPage: View"))
        let actualView = String(chatPage[start.lowerBound...])

        XCTAssertTrue(actualView.contains(permittedDiscussionMergeMenuAction))
        XCTAssertTrue(
            actualView.contains("model.handleComposerSuggestionKey(key)"))
        XCTAssertTrue(
            actualView.contains("model.slashCommandSelectedIndex == idx"))
        XCTAssertTrue(
            actualView.contains("model.applySlashCommandSuggestion(item)"))
        XCTAssertTrue(actualView.contains("chatModeOSMenuButton"))
        XCTAssertTrue(actualView.contains(
            ".accessibilityIdentifier(\"chat-composer-send\")"))
    }

    func testBrowserUsesSelectedThreadAsItsSessionBoundary() throws {
        let chatPage = try source(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPage.swift")
        let browser = try orderedRange(
            "EmbeddedBrowserView(",
            in: chatPage)
        let session = try orderedRange(
            "sessionID: model.selectedThreadID?.uuidString.lowercased()",
            in: chatPage,
            after: browser.upperBound)
        let surface = try orderedRange(
            ".liquidGlassSurface(",
            in: chatPage,
            after: session.upperBound)

        XCTAssertLessThan(browser.lowerBound, session.lowerBound)
        XCTAssertLessThan(session.lowerBound, surface.lowerBound)
    }

    func testTranscriptProjectionAndScrollDestinationStayPreciselyWired()
        throws
    {
        let chatPage = try source(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPage.swift")
        let models = try source(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModels.swift")

        let transcript = try orderedRange(
            "private struct TranscriptScrollView: View",
            in: chatPage)
        let builder = try orderedRange(
            "ChatTranscriptDisplayBuilder.build(",
            in: chatPage,
            after: transcript.upperBound)
        let projectedInput = try orderedRange(
            "planThoughtPresentationMessages)",
            in: chatPage,
            after: builder.upperBound)
        let projection = try orderedRange(
            "ChatPlanThoughtPresentation.projectedMessages(",
            in: chatPage,
            after: projectedInput.upperBound)
        let planArtifactBinding = try orderedRange(
            "planArtifactSourceMessageID:",
            in: chatPage,
            after: projection.upperBound)
        let activePlanBinding = try orderedRange(
            "activePlanTurnAssistantMessageID:",
            in: chatPage,
            after: planArtifactBinding.upperBound)
        let scroll = try orderedRange(
            "ChatTranscriptScrollDestination.resolve(",
            in: chatPage,
            after: activePlanBinding.upperBound)
        let latestAssistant = try orderedRange(
            "latestAssistantMessageID: latestAssistantMessageID",
            in: chatPage,
            after: scroll.upperBound)
        let planArtifact = try orderedRange(
            "hasPlanArtifact: planArtifact != nil",
            in: chatPage,
            after: latestAssistant.upperBound)
        let writing = try orderedRange(
            "isPlanWriting: isPlanWriting",
            in: chatPage,
            after: planArtifact.upperBound)
        let planQuestions = try orderedRange(
            "latestAssistantHasPlanQuestions:",
            in: chatPage,
            after: writing.upperBound)
        let foldedExecution = try orderedRange(
            "if isConfirmedPlanExecutionPrompt(message) {",
            in: models)
        let foldedStatus = try orderedRange(
            "statusDetail: \"已送交 Work OS\"",
            in: models,
            after: foldedExecution.upperBound)

        XCTAssertLessThan(builder.lowerBound, projectedInput.lowerBound)
        XCTAssertLessThan(projection.lowerBound, planArtifactBinding.lowerBound)
        XCTAssertLessThan(
            planArtifactBinding.lowerBound,
            activePlanBinding.lowerBound)
        XCTAssertLessThan(scroll.lowerBound, latestAssistant.lowerBound)
        XCTAssertLessThan(latestAssistant.lowerBound, planArtifact.lowerBound)
        XCTAssertLessThan(planArtifact.lowerBound, writing.lowerBound)
        XCTAssertLessThan(writing.lowerBound, planQuestions.lowerBound)
        XCTAssertTrue(models.contains(
            "static let accessibilityLabel = \"思考中\""))
        XCTAssertLessThan(
            foldedExecution.lowerBound,
            foldedStatus.lowerBound)
    }

    func testPlanInspectorPersistsHandoffSelectionAndGatesExecution() throws {
        let chatPage = try source(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPage.swift")
        let model = try ChatSourceFamily.read("ChatPageModel.swift")
        let workflows = try source(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel+Workflows.swift")

        let inspector = try orderedRange(
            ".inspector(isPresented: $planInspectorPresented)",
            in: chatPage)
        let inspectorEnd = try orderedRange(
            ".onAppear {",
            in: chatPage,
            after: inspector.upperBound)
        let inspectorSource = String(
            chatPage[inspector.lowerBound..<inspectorEnd.lowerBound])
        let selectionProjection = try orderedRange(
            "selection: model.planFlowSelectionProjection?.selection",
            in: inspectorSource)
        let selectionMutation = try orderedRange(
            "onSelectionChange: model.updatePlanFlowSelection",
            in: inspectorSource,
            after: selectionProjection.upperBound)
        let execute = try orderedRange(
            "onExecute: model.confirmActivePlan",
            in: inspectorSource,
            after: selectionMutation.upperBound)
        let handoffView = try orderedRange(
            "private struct PlanExecutionHandoffView: View",
            in: chatPage)
        let handoffViewEnd = try orderedRange(
            "enum ChatSidebarLayoutPolicy",
            in: chatPage,
            after: handoffView.upperBound)
        let handoffSource = String(
            chatPage[handoffView.lowerBound..<handoffViewEnd.lowerBound])
        let persistBeforeExecute = try orderedRange(
            "persistSelection()",
            in: handoffSource)
        let blockerGuard = try orderedRange(
            "guard currentSelection.executionBlocker == nil,",
            in: handoffSource,
            after: persistBeforeExecute.upperBound)
        let inFlightGuard = try orderedRange(
            "!localActionPresentation.isInFlight,",
            in: handoffSource,
            after: blockerGuard.upperBound)
        let succeededGuard = try orderedRange(
            "localActionPresentation.phase != .succeeded",
            in: handoffSource,
            after: inFlightGuard.upperBound)
        let guardExit = try orderedRange(
            "else { return }",
            in: handoffSource,
            after: succeededGuard.upperBound)
        let executeCallback = try orderedRange(
            "onExecute()",
            in: handoffSource,
            after: guardExit.upperBound)
        let disabledGuard = try orderedRange(
            ".disabled(!confirmActionIsEnabled)",
            in: handoffSource,
            after: executeCallback.upperBound)
        let confirmGate = try orderedRange(
            "private var confirmActionIsEnabled: Bool {",
            in: handoffSource,
            after: disabledGuard.upperBound)
        let confirmGateBlocker = try orderedRange(
            "currentSelection.executionBlocker == nil",
            in: handoffSource,
            after: confirmGate.upperBound)
        let confirmGateInFlight = try orderedRange(
            "&& !localActionPresentation.isInFlight",
            in: handoffSource,
            after: confirmGateBlocker.upperBound)
        let confirmGateSucceeded = try orderedRange(
            "&& localActionPresentation.phase != .succeeded",
            in: handoffSource,
            after: confirmGateInFlight.upperBound)
        let destinationMutation = try orderedRange(
            "destination = value",
            in: handoffSource,
            after: confirmGateSucceeded.upperBound)
        let destinationPersistence = try orderedRange(
            "persistSelection()",
            in: handoffSource,
            after: destinationMutation.upperBound)
        let collaborationMutation = try orderedRange(
            "collaboration = value",
            in: handoffSource,
            after: destinationPersistence.upperBound)
        let collaborationPersistence = try orderedRange(
            "persistSelection()",
            in: handoffSource,
            after: collaborationMutation.upperBound)
        let currentSelection = try orderedRange(
            "private var currentSelection:",
            in: handoffSource,
            after: collaborationPersistence.upperBound)
        let selectedDestination = try orderedRange(
            "destination: destination",
            in: handoffSource,
            after: currentSelection.upperBound)
        let selectedCollaboration = try orderedRange(
            "collaboration: collaboration",
            in: handoffSource,
            after: selectedDestination.upperBound)
        let persistSelectionFunction = try orderedRange(
            "private func persistSelection()",
            in: handoffSource,
            after: selectedCollaboration.upperBound)
        let selectionCallback = try orderedRange(
            "onSelectionChange(currentSelection)",
            in: handoffSource,
            after: persistSelectionFunction.upperBound)
        let updateSelection = try orderedRange(
            "func updatePlanFlowSelection(",
            in: model)
        let updateSelectionEnd = try orderedRange(
            "func isMCPToolAllowed(",
            in: model,
            after: updateSelection.upperBound)
        let updateSelectionSource = String(
            model[updateSelection.lowerBound..<updateSelectionEnd.lowerBound])
        let persistArtifact = try orderedRange(
            "artifact.planFlowSelection = selection",
            in: updateSelectionSource)
        let reopenDiscussion = try orderedRange(
            "artifact.updateDiscussion(",
            in: updateSelectionSource,
            after: persistArtifact.upperBound)
        let persistPlanArtifact = try orderedRange(
            "_ = persistPlanArtifact(artifact)",
            in: updateSelectionSource,
            after: reopenDiscussion.upperBound)
        let confirmPlan = try orderedRange(
            "func confirmActivePlan()",
            in: workflows)
        let confirmPlanEnd = try orderedRange(
            "private func finishConfirmingActivePlan(",
            in: workflows,
            after: confirmPlan.upperBound)
        let confirmPlanSource = String(
            workflows[confirmPlan.lowerBound..<confirmPlanEnd.lowerBound])
        let selectionGate = try orderedRange(
            "if let selection = artifact.planFlowSelection,",
            in: confirmPlanSource)
        let blockerGate = try orderedRange(
            "let blocker = selection.executionBlocker",
            in: confirmPlanSource,
            after: selectionGate.upperBound)
        let blockerHint = try orderedRange(
            "flashComposerHint(blocker)",
            in: confirmPlanSource,
            after: blockerGate.upperBound)
        let blockerReturn = try orderedRange(
            "return",
            in: confirmPlanSource,
            after: blockerHint.upperBound)
        let artifactConfirmation = try orderedRange(
            "artifact.confirm()",
            in: confirmPlanSource,
            after: blockerReturn.upperBound)
        let finishPlan = try orderedRange(
            "private func finishConfirmingActivePlan(",
            in: workflows)
        let finishPlanEnd = try orderedRange(
            "private func reopenPlanAfterFailedConfirmation(",
            in: workflows,
            after: finishPlan.upperBound)
        let finishPlanSource = String(
            workflows[finishPlan.lowerBound..<finishPlanEnd.lowerBound])
        let finishSelection = try orderedRange(
            "if let selection = artifact.planFlowSelection {",
            in: finishPlanSource)
        let completenessGate = try orderedRange(
            "guard selection.isComplete else {",
            in: finishPlanSource,
            after: finishSelection.upperBound)

        XCTAssertLessThan(
            selectionProjection.lowerBound,
            selectionMutation.lowerBound)
        XCTAssertLessThan(selectionMutation.lowerBound, execute.lowerBound)
        XCTAssertLessThan(
            persistBeforeExecute.lowerBound,
            blockerGuard.lowerBound)
        XCTAssertLessThan(blockerGuard.lowerBound, inFlightGuard.lowerBound)
        XCTAssertLessThan(inFlightGuard.lowerBound, succeededGuard.lowerBound)
        XCTAssertLessThan(succeededGuard.lowerBound, guardExit.lowerBound)
        XCTAssertLessThan(guardExit.lowerBound, executeCallback.lowerBound)
        XCTAssertLessThan(executeCallback.lowerBound, disabledGuard.lowerBound)
        XCTAssertLessThan(disabledGuard.lowerBound, confirmGate.lowerBound)
        XCTAssertLessThan(
            confirmGate.lowerBound,
            confirmGateBlocker.lowerBound)
        XCTAssertLessThan(
            confirmGateBlocker.lowerBound,
            confirmGateInFlight.lowerBound)
        XCTAssertLessThan(
            confirmGateInFlight.lowerBound,
            confirmGateSucceeded.lowerBound)
        XCTAssertLessThan(
            destinationMutation.lowerBound,
            destinationPersistence.lowerBound)
        XCTAssertLessThan(
            destinationPersistence.lowerBound,
            collaborationMutation.lowerBound)
        XCTAssertLessThan(
            collaborationMutation.lowerBound,
            collaborationPersistence.lowerBound)
        XCTAssertLessThan(
            currentSelection.lowerBound,
            selectedDestination.lowerBound)
        XCTAssertLessThan(
            selectedDestination.lowerBound,
            selectedCollaboration.lowerBound)
        XCTAssertLessThan(
            persistSelectionFunction.lowerBound,
            selectionCallback.lowerBound)
        XCTAssertLessThan(
            persistArtifact.lowerBound,
            reopenDiscussion.lowerBound)
        XCTAssertLessThan(
            reopenDiscussion.lowerBound,
            persistPlanArtifact.lowerBound)
        XCTAssertLessThan(selectionGate.lowerBound, blockerGate.lowerBound)
        XCTAssertLessThan(blockerGate.lowerBound, blockerHint.lowerBound)
        XCTAssertLessThan(blockerHint.lowerBound, blockerReturn.lowerBound)
        XCTAssertLessThan(
            blockerReturn.lowerBound,
            artifactConfirmation.lowerBound)
        XCTAssertLessThan(
            finishSelection.lowerBound,
            completenessGate.lowerBound)
    }

    func testWorkOSAnchorIsDurableOnlyAfterAllPreDispatchGates() throws {
        let model = try ChatSourceFamily.read("ChatPageModel.swift")
        let startTurn = try orderedRange(
            "func startTurn(",
            in: model)
        let hostGate = try orderedRange(
            "guard let computerHostBinding = prepareComputerHostBinding(",
            in: model,
            after: startTurn.upperBound)
        let hostSlotGate = try orderedRange(
            "guard computerHostBindingSlot.install(computerHostBinding) else {",
            in: model,
            after: hostGate.upperBound)
        let pendingDispatchGate = try orderedRange(
            "guard preparePendingNativeDevelopmentDispatchIfNeeded(",
            in: model,
            after: hostSlotGate.upperBound)
        let durableAnchor = try orderedRange(
            "!recordCanonicalMessage(deferredCanonicalUserMessage)",
            in: model,
            after: pendingDispatchGate.upperBound)
        let runnerStart = try orderedRange(
            "let runnerIdentity = dispatchService.startRuntime(",
            in: model,
            after: durableAnchor.upperBound)

        XCTAssertLessThan(hostGate.lowerBound, hostSlotGate.lowerBound)
        XCTAssertLessThan(
            hostSlotGate.lowerBound,
            pendingDispatchGate.lowerBound)
        XCTAssertLessThan(
            pendingDispatchGate.lowerBound,
            durableAnchor.lowerBound)
        XCTAssertLessThan(durableAnchor.lowerBound, runnerStart.lowerBound)
    }
}
