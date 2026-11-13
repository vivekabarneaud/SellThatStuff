-- SellThatStuff - a tab at the auction house: what in your bags is worth more here than
-- at the vendor. Read-only for now (scan + table, nothing is posted).
--
-- Rules for the auction house window (Blizzard's): we never change its code or its data,
-- only add our own tab and our own panel on top, and watch its tabs being clicked.
-- That keeps posting (later) from being blocked.

local ADDON, ns = ...
local L = ns.L

local ItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo -- (no global GetItemInfo in Forever)
local function Money(c)
  if not c then return "" end
  local f = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString
  return f and f(math.floor(c)) or (tostring(math.floor(c)) .. "c")
end

local CUT = 0.05          -- the auction house keeps 5% of the sale
local DURATION = 1        -- the shortest auction (smallest deposit), for now
local SEARCH_TIMEOUT = 4  -- seconds to wait for a search's answer

local tab, panel
local results = {}        -- one entry per kind of item in your bags (after a scan)
local queue, current, total, done = {}, nil, 0, 0
local scannedOnce        -- a scan was started at least once (for the "nothing to sell" message)

---------------------------------------------------------------------------
-- Your bags: what could be sold at the auction house (grouped by kind of item)
---------------------------------------------------------------------------

local function Collect()
  local AH = C_AuctionHouse
  local groups, order = {}, {}
  local last = math.max(NUM_TOTAL_EQUIPPED_BAG_SLOTS or 0, (NUM_BAG_SLOTS or 4) + 1)
  for bag = 0, last do
    local okN, n = pcall(C_Container.GetContainerNumSlots, bag)
    for slot = 1, (okN and n or 0) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      -- not grey, not soulbound, worth something at the vendor, and accepted by the auction house
      if info and info.itemID and (info.quality or 0) >= 1 and not info.isBound and not info.hasNoValue then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        local okV, valid = pcall(AH.IsSellItemValid, loc, false)
        local sell = select(11, ItemInfo(info.itemID))
        if okV and valid and sell and sell > 0 then
          local okK, key = pcall(AH.GetItemKeyFromItem, loc)
          if okK and key then
            local id = key.itemID .. ":" .. (key.itemLevel or 0) .. ":" .. (key.itemSuffix or 0)
            local g = groups[id]
            if not g then
              local okS, status = pcall(AH.GetItemCommodityStatus, loc)
              g = { id = id, itemID = info.itemID, key = key, loc = loc, link = info.hyperlink,
                icon = info.iconFileID, vendor = sell, count = 0,
                commodity = okS and Enum and Enum.ItemCommodityStatus and status == Enum.ItemCommodityStatus.Commodity }
              groups[id] = g
              order[#order + 1] = g
            end
            g.count = g.count + (info.stackCount or 1)
          end
        end
      end
    end
  end
  return order
end

---------------------------------------------------------------------------
-- The scan: one search per kind of item, one at a time
---------------------------------------------------------------------------

local Refresh -- (the table, further down)

-- the cheapest price found (each, or nil if nobody sells it): gain and deposit
local function Finish(g, price)
  g.scanned = true
  g.price = price
  if price then g.gain = math.floor(price * g.count * (1 - CUT)) - g.vendor * g.count end
  local AH = C_AuctionHouse
  local ok, dep
  if g.commodity then ok, dep = pcall(AH.CalculateCommodityDeposit, g.itemID, DURATION, g.count)
  else ok, dep = pcall(AH.CalculateItemDeposit, g.loc, DURATION, g.count) end
  g.deposit = ok and dep or nil
end

local Next
local function Advance()
  current = nil
  done = done + 1
  C_Timer.After(0.1, Next)
end

function Next()
  if not panel or not panel:IsShown() then queue = {} current = nil return end
  if current then return end
  local g = table.remove(queue, 1)
  if not g then
    Refresh()
    return
  end
  local AH = C_AuctionHouse
  -- the game spaces out searches: wait until it's ready
  if AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady() then
    table.insert(queue, 1, g)
    C_Timer.After(0.2, Next)
    return
  end
  current = g
  Refresh()
  local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
  local ok = pcall(AH.SendSearchQuery, g.key, sorts, true)
  if not ok then g.noAnswer = true Finish(g, nil) Advance() return end
  C_Timer.After(SEARCH_TIMEOUT, function()
    if current == g then g.noAnswer = true Finish(g, nil) Advance() end
  end)
end

local function StartScan()
  scannedOnce = true
  results = Collect()
  queue = {}
  for _, g in ipairs(results) do queue[#queue + 1] = g end
  total, done, current = #results, 0, nil
  Refresh()
  Next()
end

local function OnCommodityResults(itemID)
  local g = current
  if not g or not g.commodity or g.itemID ~= itemID then return end
  local AH = C_AuctionHouse
  local info = (AH.GetNumCommoditySearchResults(itemID) or 0) > 0 and AH.GetCommoditySearchResultInfo(itemID, 1)
  Finish(g, info and info.unitPrice or nil)
  Advance()
end

local function OnItemResults(itemKey)
  local g = current
  if not g or g.commodity or type(itemKey) ~= "table" or itemKey.itemID ~= g.itemID then return end
  local AH = C_AuctionHouse
  local best
  for i = 1, math.min(AH.GetNumItemSearchResults(g.key) or 0, 20) do
    local r = AH.GetItemSearchResultInfo(g.key, i)
    local each = r and r.buyoutAmount and (r.buyoutAmount / math.max(r.quantity or 1, 1))
    if each and (not best or each < best) then best = each end
  end
  Finish(g, best)
  Advance()
end

---------------------------------------------------------------------------
-- The panel: a table with one row per item
---------------------------------------------------------------------------

local ROW_H = 22
local COLS = { -- key, title, width, align
  { "item", "COL_ITEM", 250, "LEFT" },
  { "qty", "COL_QTY", 45, "RIGHT" },
  { "ah", "COL_AH", 115, "RIGHT" },
  { "vendor", "COL_VENDOR", 115, "RIGHT" },
  { "gain", "COL_GAIN", 115, "RIGHT" },
  { "deposit", "COL_DEPOSIT", 90, "RIGHT" },
}
local rowFrames = {}

local function Sorted()
  local list = {}
  for _, g in ipairs(results) do list[#list + 1] = g end
  table.sort(list, function(a, b)
    local ga, gb = a.gain or -math.huge, b.gain or -math.huge
    if ga ~= gb then return ga > gb end
    return (a.link or "") < (b.link or "")
  end)
  return list
end

local function GetRow(i)
  if rowFrames[i] then return rowFrames[i] end
  local r = CreateFrame("Button", nil, panel.content)
  r:SetHeight(ROW_H)
  r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  r:SetPoint("RIGHT", panel.content, "RIGHT", 0, 0)
  r.bg = r:CreateTexture(nil, "BACKGROUND")
  r.bg:SetAllPoints()
  r.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0)
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(ROW_H - 4, ROW_H - 4)
  r.icon:SetPoint("LEFT", 4, 0)
  r.cells = {}
  local x = 0
  for _, c in ipairs(COLS) do
    local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    local left = x + (c[1] == "item" and ROW_H + 4 or 0)
    fs:SetPoint("LEFT", left, 0)
    fs:SetWidth(c[3] - (left - x) - 8)
    fs:SetJustifyH(c[4])
    fs:SetWordWrap(false)
    r.cells[c[1]] = fs
    x = x + c[3]
  end
  r:SetScript("OnEnter", function(self)
    if self.link then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink(self.link)
      GameTooltip:Show()
    end
  end)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  rowFrames[i] = r
  return r
end

function Refresh()
  if not panel then return end
  local list = Sorted()
  local worth = 0
  for i, g in ipairs(list) do
    local r = GetRow(i)
    r.link = g.link
    r.icon:SetTexture(g.icon)
    r.cells.item:SetText(g.link or "?")
    r.cells.qty:SetText(g.count)
    r.cells.vendor:SetText(Money(g.vendor))
    if not g.scanned then
      r.cells.ah:SetText(g == current and "..." or "")
      r.cells.gain:SetText("")
      r.cells.deposit:SetText("")
      r:SetAlpha(1)
    elseif not g.price then
      r.cells.ah:SetText("|cff808080" .. (g.noAnswer and L.NO_ANSWER or L.NO_PRICE) .. "|r")
      r.cells.gain:SetText("")
      r.cells.deposit:SetText(Money(g.deposit))
      r:SetAlpha(0.5)
    else
      r.cells.ah:SetText(Money(g.price))
      local good = g.gain and g.gain > 0
      if good then worth = worth + 1 end
      r.cells.gain:SetText(good and ("|cff40ff40+" .. Money(g.gain) .. "|r") or ("|cffff6060-" .. Money(-(g.gain or 0)) .. "|r"))
      r.cells.deposit:SetText(Money(g.deposit))
      r:SetAlpha(good and 1 or 0.5)
    end
    r:Show()
  end
  for i = #list + 1, #rowFrames do rowFrames[i]:Hide() end
  panel.content:SetHeight(math.max(#list * ROW_H, 1))
  if #queue > 0 or current then
    panel.status:SetText(string.format(L.SCANNING, done, total))
  elseif total > 0 then
    panel.status:SetText(string.format(L.DONE, worth, total))
  else
    panel.status:SetText("")
  end
  panel.empty:SetText(scannedOnce and total == 0 and L.NOTHING or "")
  panel.money:SetText(Money(GetMoney and GetMoney() or 0))
end

local function Header(parent)
  local x = 0
  for _, c in ipairs(COLS) do
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("BOTTOMLEFT", parent, "TOPLEFT", x + (c[1] == "item" and ROW_H + 4 or 0), 4)
    fs:SetWidth(c[3] - 8 - (c[1] == "item" and ROW_H + 4 or 0))
    fs:SetJustifyH(c[4])
    fs:SetText(L[c[2]])
    -- what "gain" and "deposit" mean, on hover
    local tipText = (c[1] == "gain" and L.TIP_GAIN) or (c[1] == "deposit" and L.TIP_DEPOSIT)
    if tipText then
      local hit = CreateFrame("Frame", nil, parent)
      hit:SetAllPoints(fs)
      hit:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(tipText, 1, 1, 1, 1, true)
        GameTooltip:Show()
      end)
      hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    x = x + c[3]
  end
end

local function CreatePanel()
  -- Covers the window's content, under its title and around its portrait (top left),
  -- above everything else the window shows (Blizzard's own tabs and buttons)
  local p = CreateFrame("Frame", "SellThatStuffPanel", AuctionHouseFrame)
  p:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 6, -24)
  p:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -6, 4)
  p:SetFrameLevel(AuctionHouseFrame:GetFrameLevel() + 300)
  p:EnableMouse(true)
  local PORTRAIT_W, PORTRAIT_H = 52, 40 -- (the corner left free for the portrait)
  local top = p:CreateTexture(nil, "BACKGROUND")
  top:SetPoint("TOPLEFT", PORTRAIT_W, 0)
  top:SetPoint("BOTTOMRIGHT", p, "TOPRIGHT", 0, -PORTRAIT_H)
  top:SetColorTexture(0.06, 0.06, 0.06, 1)
  local main = p:CreateTexture(nil, "BACKGROUND")
  main:SetPoint("TOPLEFT", 0, -PORTRAIT_H)
  main:SetPoint("BOTTOMRIGHT")
  main:SetColorTexture(0.06, 0.06, 0.06, 1)
  p:Hide()

  local scan = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  scan:SetSize(150, 24)
  scan:SetPoint("TOPRIGHT", -12, -8)
  scan:SetText(L.SCAN)
  scan:SetScript("OnClick", StartScan)
  p.scan = scan

  p.status = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  p.status:SetPoint("TOPLEFT", p, "TOPLEFT", PORTRAIT_W + 12, -14)
  p.status:SetPoint("TOPRIGHT", scan, "TOPLEFT", -12, -6)
  p.status:SetJustifyH("LEFT")
  p.status:SetWordWrap(false)

  -- your money, bottom left (the window's own money is under our panel)
  p.money = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  p.money:SetPoint("BOTTOMLEFT", 14, 9)
  local note = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("BOTTOMRIGHT", -14, 10)
  note:SetText(L.READONLY)

  local sf = CreateFrame("ScrollFrame", nil, p, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 12, -64)
  sf:SetPoint("BOTTOMRIGHT", -30, 32)
  local content = CreateFrame("Frame", nil, sf)
  content:SetSize(1, 1)
  sf:SetScrollChild(content)
  sf:SetScript("OnSizeChanged", function(self, w) content:SetWidth(w) end)
  p.content = content
  Header(sf)

  -- in the middle of the table when it's empty
  p.empty = p:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  p.empty:SetPoint("CENTER", sf, "CENTER", 0, 0)

  p:SetScript("OnHide", function() queue = {} current = nil end)
  panel = p
  Refresh()
end

---------------------------------------------------------------------------
-- The tab at the bottom of the auction house window
---------------------------------------------------------------------------

local function BlizzardTabs()
  local out = {}
  for _, t in ipairs(AuctionHouseFrame.Tabs or {}) do out[#out + 1] = t end
  if #out == 0 then
    for _, k in ipairs({ "BuyTab", "SellTab", "AuctionsTab" }) do
      if AuctionHouseFrame[k] then out[#out + 1] = AuctionHouseFrame[k] end
    end
  end
  return out
end

local function Select(on)
  if not tab then return end
  panel:SetShown(on)
  if on then
    StartScan() -- (straight away: what's in your bags, and their prices as they come)
    pcall(PanelTemplates_SelectTab, tab)
    for _, t in ipairs(BlizzardTabs()) do pcall(PanelTemplates_DeselectTab, t) end
  else
    pcall(PanelTemplates_DeselectTab, tab)
  end
end

local function CreateTab()
  if tab or not AuctionHouseFrame then return end
  CreatePanel()
  local blizz = BlizzardTabs()
  local last = blizz[#blizz]
  for i, template in ipairs({ "AuctionHouseFrameDisplayModeTabTemplate", "AuctionHouseFrameTabTemplate",
    "PanelTabButtonTemplate", "CharacterFrameTabButtonTemplate" }) do
    local ok, b = pcall(CreateFrame, "Button", "SellThatStuffTab" .. i, AuctionHouseFrame, template)
    if ok and b then tab = b break end
  end
  if not tab then return end
  tab:SetText(L.TAB)
  pcall(PanelTemplates_TabResize, tab, 0)
  if last then tab:SetPoint("LEFT", last, "RIGHT", 3, 0)
  else tab:SetPoint("TOPLEFT", AuctionHouseFrame, "BOTTOMLEFT", 20, 2) end
  pcall(PanelTemplates_DeselectTab, tab)
  tab:SetScript("OnClick", function() Select(true) end)
  -- a Blizzard tab clicked: back to the window's own content
  for _, t in ipairs(blizz) do t:HookScript("OnClick", function() Select(false) end) end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local f = CreateFrame("Frame")
for _, ev in ipairs({ "ADDON_LOADED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED" }) do
  pcall(f.RegisterEvent, f, ev)
end
f:SetScript("OnEvent", function(_, event, a)
  local ok, err = pcall(function()
    if event == "ADDON_LOADED" and a == ADDON then
      SellThatStuffDB = SellThatStuffDB or {}
    elseif event == "AUCTION_HOUSE_SHOW" then
      CreateTab()
      Select(false)
    elseif event == "AUCTION_HOUSE_CLOSED" then
      if panel then Select(false) end
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
      OnCommodityResults(a)
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
      OnItemResults(a)
    end
  end)
  if not ok then print("|cff66ccffSellThatStuff|r error (" .. event .. "): " .. tostring(err)) end
end)

SLASH_SELLTHATSTUFF1 = "/sts"
SlashCmdList.SELLTHATSTUFF = function(msg)
  msg = (msg or ""):lower()
  if msg == "probe" and ns.RunProbe then
    local ok, err = pcall(ns.RunProbe)
    if not ok then print("|cff66ccffSellThatStuff|r probe error: " .. tostring(err)) end
  else
    print("|cff66ccffSellThatStuff|r: open the auction house and click the SellThatStuff tab. /sts probe - test the auction house")
  end
end
