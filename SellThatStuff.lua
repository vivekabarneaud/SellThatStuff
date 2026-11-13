-- SellThatStuff - a tab at the auction house: what in your bags is worth more here than
-- at the vendor, and a Post button on each row (one click = one auction).
--
-- Rules for the auction house window (Blizzard's): we never change its code or its data,
-- only add our own tab and our own panel on top, and watch its tabs being clicked.
-- That keeps posting from being blocked (the game only lets addons post on a click).

local ADDON, ns = ...
local L = ns.L

local ItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo -- (no global GetItemInfo in Forever)
local function Money(c)
  if not c then return "" end
  local f = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString
  return f and f(math.floor(c)) or (tostring(math.floor(c)) .. "c")
end
local function Say(msg) print("|cff66ccffSellThatStuff|r: " .. tostring(msg)) end

local CUT = 0.05          -- the auction house keeps 5% of the sale
local SEARCH_TIMEOUT = 4  -- seconds to wait for a search's answer
local POST_TIMEOUT = 8    -- seconds to wait for "auction created"

local tab, panel
local results = {}        -- one entry per kind of item in your bags (after a scan)
local queue, current, total, done = {}, nil, 0, 0
local scannedOnce         -- a scan was started at least once (for the "nothing to sell" message)
local posting             -- { g, qty }: an auction on its way (waiting for the game's answer)
local order = {}          -- the rows, in the order shown (sorted once the scan is over, so they don't move under your cursor)

-- Auction duration: your choice (saved), else the one whose name says 8 hours (the game's
-- own labels), else the middle one
local DURATION_KEYS = { "AUCTION_DURATION_ONE", "AUCTION_DURATION_TWO", "AUCTION_DURATION_THREE" }
local function DurationLabel(i) return type(_G[DURATION_KEYS[i]]) == "string" and _G[DURATION_KEYS[i]] or tostring(i) end
local defaultDuration
local function Duration()
  local i = SellThatStuffDB and SellThatStuffDB.duration
  if not i then
    if not defaultDuration then
      defaultDuration = 2
      for j = 1, 3 do
        if DurationLabel(j):match("^%s*8%D") then defaultDuration = j end
      end
    end
    i = defaultDuration
  end
  return i, DurationLabel(i)
end

-- The least an auction must gain over the vendor to be offered (total, in copper; saved)
local function MinGain() return (SellThatStuffDB and SellThatStuffDB.minGain) or 0 end
local function GainOK(g) return g.gain and g.gain > 0 and g.gain >= MinGain() end

-- The price we post at: the cheapest one found (rounded down to silver if the auction
-- house doesn't take copper)
local function PostPrice(p)
  local AH = C_AuctionHouse
  if AH.SupportsCopperValues and not AH.SupportsCopperValues() then
    return math.max(100, math.floor(p / 100) * 100)
  end
  return math.max(1, math.floor(p))
end

---------------------------------------------------------------------------
-- Your bags: what could be sold at the auction house (grouped by kind of item)
---------------------------------------------------------------------------

-- every stack in your bags that could go to the auction house: fn(bag, slot, info, loc, key, id, vendorPrice)
local function ForEachSellable(fn)
  local AH = C_AuctionHouse
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
            fn(bag, slot, info, loc, key, id, sell)
          end
        end
      end
    end
  end
end

local function MaxQty(g)
  if not g.loc then return 0 end
  if not g.commodity then return g.stacks[1] and g.stacks[1].count or 1 end -- (an item: one stack per auction)
  local AH = C_AuctionHouse
  local ok, n = pcall(AH.GetAvailablePostCount, g.loc)
  return (ok and n and n > 0) and n or g.count
end

local function Collect()
  local AH = C_AuctionHouse
  local groups, order = {}, {}
  ForEachSellable(function(bag, slot, info, loc, key, id, sell)
    local g = groups[id]
    if not g then
      local okS, status = pcall(AH.GetItemCommodityStatus, loc)
      g = { id = id, itemID = info.itemID, key = key, loc = loc, link = info.hyperlink,
        icon = info.iconFileID, vendor = sell, count = 0, stacks = {},
        commodity = okS and Enum and Enum.ItemCommodityStatus and status == Enum.ItemCommodityStatus.Commodity }
      groups[id] = g
      order[#order + 1] = g
    end
    g.count = g.count + (info.stackCount or 1)
    g.stacks[#g.stacks + 1] = { bag = bag, slot = slot, count = info.stackCount or 1 }
  end)
  for _, g in ipairs(order) do g.qty = MaxQty(g) end
  return order
end

-- What's left of an item in your bags (after posting, or if you moved things around)
local function Recount(g)
  g.count, g.stacks, g.loc = 0, {}, nil
  ForEachSellable(function(bag, slot, info, loc, key, id)
    if id == g.id then
      g.loc = g.loc or loc
      g.count = g.count + (info.stackCount or 1)
      g.stacks[#g.stacks + 1] = { bag = bag, slot = slot, count = info.stackCount or 1 }
    end
  end)
  g.qty = math.min(g.qty or 0, MaxQty(g))
  if g.qty <= 0 then g.qty = MaxQty(g) end
end

-- gain and deposit for the quantity chosen
local function Recalc(g)
  if g.price then
    local each = PostPrice(g.price)
    g.gain = math.floor(each * g.qty * (1 - CUT)) - g.vendor * g.qty
  end
  local AH = C_AuctionHouse
  local ok, dep
  if g.qty <= 0 or not g.loc then g.deposit = nil return end
  if g.commodity then ok, dep = pcall(AH.CalculateCommodityDeposit, g.itemID, Duration(), g.qty)
  else ok, dep = pcall(AH.CalculateItemDeposit, g.loc, Duration(), g.qty) end
  g.deposit = ok and dep or nil
end

---------------------------------------------------------------------------
-- The scan: one search per kind of item, one at a time
---------------------------------------------------------------------------

local Refresh, SortRows, UpdateRow -- (the table, further down)

-- the cheapest price found (each, or nil if nobody sells it)
local function Finish(g, price)
  g.scanned = true
  g.price = price
  Recalc(g)
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
  -- the game spaces out searches (and an auction being posted goes first): wait until it's ready
  if posting or (AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady()) then
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
  order = {}
  for _, g in ipairs(results) do order[#order + 1] = g end
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
-- Posting (on a click: the game only allows it then)
---------------------------------------------------------------------------

local function Worth(g) return g.scanned and g.price and GainOK(g) and g.qty > 0 end

-- Is the item still where we saw it? (you may have moved things around since the scan)
local function StillThere(g)
  local s = g.stacks and g.stacks[1]
  local info = s and C_Container.GetContainerItemInfo(s.bag, s.slot)
  return info and info.itemID == g.itemID
end

local function Post(g)
  local AH = C_AuctionHouse
  if posting or not Worth(g) then return end
  if not StillThere(g) then
    Recount(g) Recalc(g) Refresh()
    if not g.loc or not Worth(g) then return end
  end
  if AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady() then
    Say(L.WAIT)
    return
  end
  local each = PostPrice(g.price)
  local ok, err
  if g.commodity then ok, err = pcall(AH.PostCommodity, g.loc, Duration(), g.qty, each)
  else ok, err = pcall(AH.PostItem, g.loc, Duration(), g.qty, nil, each * g.qty) end
  if not ok then Say(L.POST_FAILED .. " " .. tostring(err)) return end
  posting = { g = g, qty = g.qty }
  g.state = "posting"
  Refresh()
  C_Timer.After(POST_TIMEOUT, function()
    if posting and posting.g == g then
      posting = nil
      if g.state == "posting" then g.state = nil end
      Recount(g) Recalc(g) Refresh()
    end
  end)
end

-- the game asks to confirm (an unusual price...): the row's button becomes "Confirm"
local function Confirm(g)
  local AH = C_AuctionHouse
  if g.state ~= "confirm" then return end
  local ok = pcall(g.commodity and AH.ConfirmPostCommodity or AH.ConfirmPostItem)
  g.state = ok and "posting" or nil
  Refresh()
end

local function OnPosted()
  local p = posting
  posting = nil
  if not p then return end
  local g = p.g
  g.posted = (g.posted or 0) + p.qty
  g.state = nil
  -- the bags update a moment later
  C_Timer.After(0.5, function()
    Recount(g)
    if g.count <= 0 then g.state = "done" end
    Recalc(g)
    Refresh()
  end)
  Refresh()
end

---------------------------------------------------------------------------
-- The panel: a table with one row per item
---------------------------------------------------------------------------

local ROW_H = 24
local COLS = { -- key, title, width, align
  { "item", "COL_ITEM", 215, "LEFT" },
  { "qty", "COL_QTY", 55, "RIGHT" },
  { "ah", "COL_AH", 95, "RIGHT" },
  { "vendor", "COL_EACH", 95, "RIGHT" }, -- (gain per unit, compared with the vendor)
  { "gain", "COL_TOTAL", 105, "RIGHT" },
  { "deposit", "COL_DEPOSIT", 75, "RIGHT" },
  { "post", "", 85, "RIGHT" },
}
local rowFrames = {}

function SortRows()
  local list = {}
  for _, g in ipairs(results) do list[#list + 1] = g end
  local function rank(g) return g.state == "done" and 1 or 0 end -- (posted rows go last)
  table.sort(list, function(a, b)
    if rank(a) ~= rank(b) then return rank(a) < rank(b) end
    local ga, gb = a.gain or -math.huge, b.gain or -math.huge
    if ga ~= gb then return ga > gb end
    return (a.link or "") < (b.link or "")
  end)
  return list
end

local function ColX(key)
  local x = 0
  for _, c in ipairs(COLS) do
    if c[1] == key then return x, c[3] end
    x = x + c[3]
  end
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
  r.icon:SetSize(ROW_H - 6, ROW_H - 6)
  r.icon:SetPoint("LEFT", 4, 0)
  r.cells = {}
  local x = 0
  for _, c in ipairs(COLS) do
    if c[1] ~= "qty" and c[1] ~= "post" then
      local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      local left = x + (c[1] == "item" and ROW_H + 2 or 0)
      fs:SetPoint("LEFT", left, 0)
      fs:SetWidth(c[3] - (left - x) - 8)
      fs:SetJustifyH(c[4])
      fs:SetWordWrap(false)
      r.cells[c[1]] = fs
    end
    x = x + c[3]
  end
  -- how many to post (all of it by default)
  local qx, qw = ColX("qty")
  local qty = CreateFrame("EditBox", nil, r, "InputBoxTemplate")
  qty:SetSize(qw - 18, 16)
  qty:SetPoint("CENTER", r, "LEFT", qx + qw / 2, 0)
  qty:SetAutoFocus(false)
  qty:SetNumeric(true)
  qty:SetMaxLetters(4)
  qty:SetJustifyH("CENTER")
  qty:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  qty:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  qty:SetScript("OnTextChanged", function(self, user)
    local g = r.g
    if not user or not g then return end
    local n = tonumber(self:GetText())
    if not n then return end
    g.qty = math.max(0, math.min(n, MaxQty(g)))
    Recalc(g)
    UpdateRow(r, g) -- (just this row: nothing moves while you type)
  end)
  qty:SetScript("OnEditFocusLost", function(self)
    if r.g then self:SetText(r.g.qty) end
  end)
  r.qty = qty
  -- one click = one auction
  local px, pw = ColX("post")
  local post = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
  post:SetSize(pw - 10, ROW_H - 4)
  post:SetPoint("RIGHT", r, "LEFT", px + pw - 4, 0)
  post:SetScript("OnClick", function()
    local g = r.g
    if not g then return end
    if g.state == "confirm" then Confirm(g) else Post(g) end
  end)
  r.post = post
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

local function SetRowButton(r, g)
  local b = r.post
  if g.state == "done" then
    b:SetText(L.POSTED) b:Disable() b:Show()
  elseif g.state == "posting" then
    b:SetText("...") b:Disable() b:Show()
  elseif g.state == "confirm" then
    b:SetText(L.CONFIRM) b:Enable() b:Show()
  elseif Worth(g) then
    b:SetText(L.POST)
    b:SetEnabled(not posting)
    b:Show()
  else
    b:Hide()
  end
end

-- one row: returns true if it's worth posting
function UpdateRow(r, g)
    local worthIt = false
    r.g = g
    r.link = g.link
    r.icon:SetTexture(g.icon)
    r.cells.item:SetText(g.link or "?")
    -- per unit: what the auction house pays (after its cut) minus what the vendor pays
    local each = g.price and (math.floor(PostPrice(g.price) * (1 - CUT)) - g.vendor)
    r.cells.vendor:SetText(not each and "" or each > 0 and ("|cff40ff40+" .. Money(each) .. "|r")
      or ("|cffff6060-" .. Money(-each) .. "|r"))
    if not r.qty:HasFocus() then r.qty:SetText(g.qty or 0) end
    r.qty:SetShown(g.state ~= "done")
    if g.commodity and g.state == nil then r.qty:Enable() else r.qty:Disable() end
    if not g.scanned then
      r.cells.ah:SetText(g == current and "..." or "")
      r.cells.gain:SetText("")
      r.cells.deposit:SetText("")
      r:SetAlpha(1)
    elseif not g.price then
      r.cells.ah:SetText("|cff808080" .. (g.noAnswer and L.NO_ANSWER or L.NO_PRICE) .. "|r")
      r.cells.gain:SetText("")
      r.cells.deposit:SetText("")
      r:SetAlpha(0.5)
    else
      r.cells.ah:SetText(Money(PostPrice(g.price)))
      local good = GainOK(g) -- (worth it: gains something, and at least your minimum)
      worthIt = good
      if g.state == "done" then
        r.cells.gain:SetText("")
        r.cells.deposit:SetText("")
      else
        r.cells.gain:SetText(not g.gain and "" or g.gain > 0 and ("|cff40ff40+" .. Money(g.gain) .. "|r")
          or ("|cffff6060-" .. Money(-g.gain) .. "|r"))
        r.cells.deposit:SetText(Money(g.deposit))
      end
      r:SetAlpha((good or g.state == "done") and 1 or 0.5)
    end
    SetRowButton(r, g)
    r:Show()
    return worthIt
end

function Refresh()
  if not panel then return end
  local list = order
  local worth = 0
  for i, g in ipairs(list) do
    if UpdateRow(GetRow(i), g) then worth = worth + 1 end
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
  -- the duration in use stays lit
  for i, b in ipairs(panel.durButtons) do
    if i == Duration() then b:LockHighlight() else b:UnlockHighlight() end
  end
  panel.ShowMinGain()
end

local function Header(parent)
  local x = 0
  for _, c in ipairs(COLS) do
    if c[2] ~= "" then
      local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      fs:SetPoint("BOTTOMLEFT", parent, "TOPLEFT", x + (c[1] == "item" and ROW_H + 2 or 0), 4)
      fs:SetWidth(c[3] - 8 - (c[1] == "item" and ROW_H + 2 or 0))
      fs:SetJustifyH(c[4])
      fs:SetText(L[c[2]])
      -- what "gain" and "deposit" mean, on hover
      local tipText = (c[1] == "gain" and L.TIP_GAIN) or (c[1] == "deposit" and L.TIP_DEPOSIT) or (c[1] == "vendor" and L.TIP_EACH)
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
  -- Our background leaves the corner under the window's portrait open (so the portrait
  -- shows); a dark patch slipped under the portrait, on its own frame, hides what the
  -- window draws there (a grey square).
  local PORTRAIT_W, PORTRAIT_H = 52, 40
  local DARK = { 0.06, 0.06, 0.06, 1 }
  local top = p:CreateTexture(nil, "BACKGROUND")
  top:SetPoint("TOPLEFT", PORTRAIT_W, 0)
  top:SetPoint("BOTTOMRIGHT", p, "TOPRIGHT", 0, -PORTRAIT_H)
  top:SetColorTexture(unpack(DARK))
  local main = p:CreateTexture(nil, "BACKGROUND")
  main:SetPoint("TOPLEFT", 0, -PORTRAIT_H)
  main:SetPoint("BOTTOMRIGHT")
  main:SetColorTexture(unpack(DARK))
  local portrait = (AuctionHouseFrame.PortraitContainer and AuctionHouseFrame.PortraitContainer.portrait)
    or AuctionHouseFrame.portrait or _G.AuctionHouseFramePortrait
  local holder = portrait and portrait.GetParent and portrait:GetParent()
  if holder and holder ~= AuctionHouseFrame and holder.CreateTexture then
    p.corner = holder:CreateTexture(nil, "BACKGROUND", nil, -8)
    p.corner:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0)
    p.corner:SetPoint("BOTTOMRIGHT", p, "TOPLEFT", PORTRAIT_W, -PORTRAIT_H)
    p.corner:SetColorTexture(unpack(DARK))
    p.corner:Hide()
  else -- (the portrait isn't on a frame of its own: just cover the corner)
    local corner = p:CreateTexture(nil, "BACKGROUND")
    corner:SetPoint("TOPLEFT")
    corner:SetPoint("BOTTOMRIGHT", p, "TOPLEFT", PORTRAIT_W, -PORTRAIT_H)
    corner:SetColorTexture(unpack(DARK))
  end
  p:Hide()
  local scan = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  scan:SetSize(120, 24)
  scan:SetPoint("TOPRIGHT", -12, -8)
  scan:SetText(L.SCAN)
  scan:SetScript("OnClick", StartScan)
  p.scan = scan
  -- sort by gain (on demand only: rows never move by themselves)
  local sort = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  sort:SetSize(120, 24)
  sort:SetPoint("RIGHT", scan, "LEFT", -6, 0)
  sort:SetText(L.SORT)
  sort:SetScript("OnClick", function()
    order = SortRows()
    Refresh()
  end)
  p.sort = sort

  p.status = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  p.status:SetPoint("TOPLEFT", p, "TOPLEFT", PORTRAIT_W + 12, -14)
  p.status:SetPoint("TOPRIGHT", sort, "TOPLEFT", -12, -6)
  p.status:SetJustifyH("LEFT")
  p.status:SetWordWrap(false)

  -- Bottom bar: your money (the window's own is under our panel), the minimum gain and the
  -- auction duration (both saved)
  p.money = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  p.money:SetPoint("BOTTOMLEFT", 14, 11)

  local minLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  minLabel:SetPoint("BOTTOMLEFT", 150, 12)
  minLabel:SetText(L.MIN_GAIN)
  local tipHit = CreateFrame("Frame", nil, p)
  tipHit:SetAllPoints(minLabel)
  tipHit:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L.TIP_MIN_GAIN, 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  tipHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
  local COIN = { "|TInterface/MoneyFrame/UI-GoldIcon:12:12|t", "|TInterface/MoneyFrame/UI-SilverIcon:12:12|t",
    "|TInterface/MoneyFrame/UI-CopperIcon:12:12|t" }
  local MULT = { 10000, 100, 1 }
  p.minBoxes = {}
  local anchor = minLabel
  for i = 1, 3 do
    local b = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
    b:SetSize(i == 1 and 36 or 24, 16)
    b:SetPoint("LEFT", anchor, "RIGHT", i == 1 and 12 or 8, 0)
    b:SetAutoFocus(false)
    b:SetNumeric(true)
    b:SetMaxLetters(i == 1 and 4 or 2)
    b:SetJustifyH("CENTER")
    local coin = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    coin:SetPoint("LEFT", b, "RIGHT", 2, 0)
    coin:SetText(COIN[i])
    b:SetScript("OnTextChanged", function(self, user)
      if not user then return end
      local c = 0
      for j = 1, 3 do c = c + (tonumber(p.minBoxes[j]:GetText()) or 0) * MULT[j] end
      SellThatStuffDB.minGain = c
      Refresh()
    end)
    b:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    b:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    p.minBoxes[i] = b
    anchor = coin
  end
  function p.ShowMinGain()
    local c = MinGain()
    local parts = { math.floor(c / 10000), math.floor(c % 10000 / 100), c % 100 }
    for i, b in ipairs(p.minBoxes) do
      if not b:HasFocus() then b:SetText(parts[i]) end
    end
  end

  p.durButtons = {}
  local prev
  for i = 3, 1, -1 do -- (from the right)
    local b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    b:SetSize(78, 20)
    if prev then b:SetPoint("RIGHT", prev, "LEFT", -4, 0) else b:SetPoint("BOTTOMRIGHT", -14, 8) end
    b:SetText(DurationLabel(i))
    b:SetScript("OnClick", function()
      SellThatStuffDB.duration = i
      for _, g in ipairs(results) do Recalc(g) end -- (the deposit depends on it)
      Refresh()
    end)
    p.durButtons[i] = b
    prev = b
  end
  local durLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  durLabel:SetPoint("RIGHT", prev, "LEFT", -8, 0)
  durLabel:SetText(L.DURATION)

  local sf = CreateFrame("ScrollFrame", nil, p, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 12, -64)
  sf:SetPoint("BOTTOMRIGHT", -30, 36)
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
  for _, t in ipairs(AuctionHouseFrame.Tabs or {}) do
    if t ~= tab and not (t.GetName and (t:GetName() or ""):find("^SellThatStuff")) then out[#out + 1] = t end
  end
  if #out == 0 then
    for _, k in ipairs({ "BuyTab", "SellTab", "AuctionsTab" }) do
      if AuctionHouseFrame[k] then out[#out + 1] = AuctionHouseFrame[k] end
    end
  end
  return out
end

local STRATA = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }

-- Above everything the window shows right now (some of Blizzard's frames sit very high:
-- the Sell tab's item slot and buttons, the Auctions tab's top tab...)
local function RaisePanel()
  local topStrata, topLevel = AuctionHouseFrame:GetFrameStrata(), AuctionHouseFrame:GetFrameLevel()
  local function Walk(frame, depth)
    for _, c in ipairs({ frame:GetChildren() }) do
      if c ~= panel and c ~= tab and c:IsShown() then
        local s = c:GetFrameStrata()
        if (STRATA[s] or 0) > (STRATA[topStrata] or 0) then topStrata, topLevel = s, c:GetFrameLevel()
        elseif s == topStrata then topLevel = math.max(topLevel, c:GetFrameLevel()) end
        if depth < 8 then Walk(c, depth + 1) end
      end
    end
  end
  Walk(AuctionHouseFrame, 0)
  if (STRATA[topStrata] or 0) >= STRATA.TOOLTIP then topStrata = "FULLSCREEN_DIALOG" end
  panel:SetFrameStrata(topStrata)
  panel:SetFrameLevel(math.min(topLevel + 10, 9000))
end

local function Select(on)
  if not tab then return end
  if on then RaisePanel() end
  panel:SetShown(on)
  if panel.corner then panel.corner:SetShown(on) end
  if on then
    -- straight away the first time (what's in your bags, and their prices as they come);
    -- after that, the table stays as it was until you rescan or leave the auction house
    if not scannedOnce then StartScan() else Refresh() end
    -- (what happens when we give our tab the "selected" look: noted for the next fix)
    local okSel, errSel = pcall(PanelTemplates_SelectTab, tab)
    SellThatStuffDB.tabSelect = okSel and "ok" or tostring(errSel)
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
  -- (the game's generic tab: the auction house's own tab style adds itself to Blizzard's list of
  -- tabs, which must stay theirs only)
  for i, template in ipairs({ "PanelTabButtonTemplate", "CharacterFrameTabButtonTemplate" }) do
    local ok, b = pcall(CreateFrame, "Button", "SellThatStuffTab" .. i, AuctionHouseFrame, template)
    if ok and b then tab = b SellThatStuffDB.tabTemplate = template break end
    if not ok then SellThatStuffDB["tabTemplateError" .. i] = tostring(b) end
  end
  if not tab then return end
  tab:SetText(L.TAB)
  pcall(PanelTemplates_TabResize, tab, 0)
  if last then tab:SetPoint("LEFT", last, "RIGHT", 3, 0)
  else tab:SetPoint("TOPLEFT", AuctionHouseFrame, "BOTTOMLEFT", 20, 2) end
  pcall(PanelTemplates_DeselectTab, tab)
  tab:SetScript("OnClick", function() Select(true) end)
  -- a Blizzard tab clicked: back to the window's own content
  -- (and give the clicked tab its selected look back: the window does nothing when you click
  -- the tab it thinks is already open)
  for _, t in ipairs(blizz) do
    t:HookScript("OnClick", function(self)
      Select(false)
      pcall(PanelTemplates_SelectTab, self)
    end)
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local f = CreateFrame("Frame")
for _, ev in ipairs({ "ADDON_LOADED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
  "AUCTION_HOUSE_AUCTION_CREATED", "AUCTION_HOUSE_POST_WARNING", "AUCTION_HOUSE_POST_ERROR", "PLAYER_MONEY" }) do
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
      scannedOnce = nil -- (next visit: a fresh scan)
      posting = nil
      if panel then Select(false) end
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
      OnCommodityResults(a)
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
      OnItemResults(a)
    elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
      OnPosted()
    elseif event == "AUCTION_HOUSE_POST_WARNING" then
      if posting then posting.g.state = "confirm" Refresh() end
    elseif event == "AUCTION_HOUSE_POST_ERROR" then
      if posting then
        posting.g.state = nil
        posting = nil
        Refresh()
      end
    elseif event == "PLAYER_MONEY" then
      if panel and panel:IsShown() then Refresh() end
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
