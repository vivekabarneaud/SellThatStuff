-- SellThatStuff - probe: what the auction house offers addons in this client.
-- /sts probe   (at an auction house, with a few items in your bags)
-- Lists the auction house functions, then searches the auction house for 2 items from
-- your bags and records what comes back. It never posts or buys anything.
-- Saved in SellThatStuffDB.probe (read after logging out), and summed up in the chat.

local ADDON = ...

local ahOpen = false
local pending = {}   -- searches waiting for results: key -> record
local probe          -- the current probe record

local function Print(...) print("|cff66ccffSellThatStuff|r:", ...) end

local function Keys(t)
  local out = {}
  if type(t) ~= "table" then return out end
  for k, v in pairs(t) do out[#out + 1] = tostring(k) .. (type(v) == "function" and "()" or "") end
  table.sort(out)
  return out
end

local function Try(label, f, ...)
  local ok, a, b, c = pcall(f, ...)
  if not ok then return { label = label, error = tostring(a) } end
  return { label = label, a = a, b = b, c = c }
end

-- a table result made safe to save (copies plain values one level down)
local function Plain(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do
    if type(x) == "table" then
      local inner = {}
      for k2, y in pairs(x) do if type(y) ~= "table" and type(y) ~= "function" then inner[k2] = y end end
      out[k] = inner
    elseif type(x) ~= "function" then out[k] = x end
  end
  return out
end

-- Up to 2 items from your bags worth trying: not grey, not soulbound, with a vendor price
local function TestItems()
  local found = {}
  local last = math.max(NUM_TOTAL_EQUIPPED_BAG_SLOTS or 0, (NUM_BAG_SLOTS or 4) + 1)
  for bag = 0, last do
    local okN, n = pcall(C_Container.GetContainerNumSlots, bag)
    for slot = 1, (okN and n or 0) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID and (info.quality or 0) >= 1 and not info.isBound and not info.hasNoValue then
        found[#found + 1] = { bag = bag, slot = slot, info = info }
        if #found >= 2 then return found end
      end
    end
  end
  return found
end

local function RecordItem(t)
  local r = { bag = t.bag, slot = t.slot, itemID = t.info.itemID, link = t.info.hyperlink,
    quality = t.info.quality, stack = t.info.stackCount }
  local _, _, _, _, _, _, _, maxStack, _, _, sellPrice = GetItemInfo(t.info.itemID)
  r.vendorPrice, r.maxStack = sellPrice, maxStack
  local loc = ItemLocation and ItemLocation.CreateFromBagAndSlot and ItemLocation:CreateFromBagAndSlot(t.bag, t.slot)
  r.hasItemLocation = loc ~= nil
  local AH = C_AuctionHouse
  if loc and C_Item and C_Item.IsBound then r.isBound = Try("IsBound", C_Item.IsBound, loc) end
  if AH and loc then
    r.commodityStatus = AH.GetItemCommodityStatus and Try("GetItemCommodityStatus", AH.GetItemCommodityStatus, loc)
    r.depositItem = {}
    r.depositCommodity = {}
    for duration = 1, 3 do
      if AH.CalculateItemDeposit then r.depositItem[duration] = Try("CalculateItemDeposit", AH.CalculateItemDeposit, loc, duration, 1) end
      if AH.CalculateCommodityDeposit then
        r.depositCommodity[duration] = Try("CalculateCommodityDeposit", AH.CalculateCommodityDeposit, t.info.itemID, duration, 1)
      end
    end
  end
  return r
end

local function Search(r)
  local AH = C_AuctionHouse
  if not (AH and AH.MakeItemKey and AH.SendSearchQuery) then r.search = "no MakeItemKey / SendSearchQuery" return end
  local key = AH.MakeItemKey(r.itemID)
  r.itemKey = Plain(key)
  local sorts = {}
  if Enum and Enum.AuctionHouseSortOrder then
    sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
  end
  r.sentAt = GetTime()
  pending[r.itemID] = r
  r.sent = Try("SendSearchQuery", AH.SendSearchQuery, key, sorts, true)
end

-- results came back: commodities (stackable, priced per unit) or items (each auction apart)
local function OnCommodity(itemID)
  local r = pending[itemID]
  if not r then return end
  local AH = C_AuctionHouse
  r.event = "COMMODITY_SEARCH_RESULTS_UPDATED"
  r.after = GetTime() - (r.sentAt or GetTime())
  r.num = AH.GetNumCommoditySearchResults and AH.GetNumCommoditySearchResults(itemID)
  r.results = {}
  for i = 1, math.min(r.num or 0, 3) do
    r.results[i] = Plain(AH.GetCommoditySearchResultInfo(itemID, i))
  end
  r.full = AH.HasFullCommoditySearchResults and AH.HasFullCommoditySearchResults(itemID)
  Print(r.link or r.itemID, "commodity:", r.num or "?", "results",
    r.results[1] and ("cheapest " .. GetCoinTextureString(r.results[1].unitPrice or 0) .. " each") or "")
end

local function OnItems(itemKey)
  local id = type(itemKey) == "table" and itemKey.itemID
  local r = id and pending[id]
  if not r then return end
  local AH = C_AuctionHouse
  r.event = "ITEM_SEARCH_RESULTS_UPDATED"
  r.after = GetTime() - (r.sentAt or GetTime())
  r.num = AH.GetNumItemSearchResults and AH.GetNumItemSearchResults(itemKey)
  r.results = {}
  for i = 1, math.min(r.num or 0, 3) do
    r.results[i] = Plain(AH.GetItemSearchResultInfo(itemKey, i))
  end
  r.full = AH.HasFullItemSearchResults and AH.HasFullItemSearchResults(itemKey)
  local first = r.results[1]
  Print(r.link or r.itemID, "item:", r.num or "?", "results",
    first and ("cheapest " .. GetCoinTextureString(first.buyoutAmount or first.bidAmount or 0)) or "")
end

local function RunProbe()
  local db = SellThatStuffDB
  probe = { at = date("%Y-%m-%d %H:%M:%S"), ahOpen = ahOpen, build = { GetBuildInfo() } }
  db.probe = probe
  probe.has = {
    C_AuctionHouse = C_AuctionHouse ~= nil,
    AuctionHouseFrame = AuctionHouseFrame ~= nil,
    AuctionFrame = AuctionFrame ~= nil,               -- the old auction house window
    QueryAuctionItems = QueryAuctionItems ~= nil,     -- the old API
    PostAuction = PostAuction ~= nil,
    ItemLocation = ItemLocation ~= nil,
    C_Item_IsBound = C_Item and C_Item.IsBound ~= nil,
    SortOrderEnum = Enum and Enum.AuctionHouseSortOrder ~= nil,
    CommodityStatusEnum = Enum and Enum.ItemCommodityStatus ~= nil,
  }
  probe.functions = Keys(C_AuctionHouse)
  if Enum then
    probe.enums = { sort = Plain(Enum.AuctionHouseSortOrder), commodity = Plain(Enum.ItemCommodityStatus),
      duration = Plain(Enum.AuctionHouseTimeLeftBand) }
  end
  local AH = C_AuctionHouse
  if AH and AH.IsThrottledMessageSystemReady then probe.throttleReady = AH.IsThrottledMessageSystemReady() end
  Print(("C_AuctionHouse: %s (%d functions). Old API: %s."):format(
    C_AuctionHouse and "yes" or "NO", #probe.functions, QueryAuctionItems and "yes" or "no"))
  if not ahOpen then
    Print("Open an auction house and type /sts probe again to test a search.")
    return
  end
  probe.items = {}
  for i, t in ipairs(TestItems()) do
    local r = RecordItem(t)
    probe.items[i] = r
    -- one search at a time (the game throttles them)
    C_Timer.After((i - 1) * 2, function() Search(r) end)
  end
  if #probe.items == 0 then Print("No item to test in your bags (not grey, not soulbound).") return end
  Print("Searching for", #probe.items, "item(s)... (nothing is posted)")
  C_Timer.After(8, function()
    for _, r in ipairs(probe.items) do
      if not r.event then r.event = "no results event after 8 s" Print(r.link or r.itemID, "- no answer") end
    end
    Print("Done. Log out (or /reload) so I can read the results.")
  end)
end

local f = CreateFrame("Frame")
for _, ev in ipairs({ "ADDON_LOADED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" }) do
  pcall(f.RegisterEvent, f, ev)
end
f:SetScript("OnEvent", function(_, event, a, b)
  local ok, err = pcall(function()
    if event == "ADDON_LOADED" and a == ADDON then
      SellThatStuffDB = SellThatStuffDB or {}
    elseif event == "AUCTION_HOUSE_SHOW" then
      ahOpen = true
    elseif event == "AUCTION_HOUSE_CLOSED" then
      ahOpen = false
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
      OnCommodity(a)
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
      OnItems(a)
    elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" and probe then
      probe.throttleEvents = (probe.throttleEvents or 0) + 1
    end
  end)
  if not ok then Print("error in " .. event .. ": " .. tostring(err)) end
end)

SLASH_SELLTHATSTUFF1 = "/sts"
SlashCmdList.SELLTHATSTUFF = function(msg)
  msg = (msg or ""):lower()
  if msg == "probe" then
    local ok, err = pcall(RunProbe)
    if not ok then Print("probe error: " .. tostring(err)) end
  else
    Print("/sts probe - test what the auction house offers (at an auction house)")
  end
end
