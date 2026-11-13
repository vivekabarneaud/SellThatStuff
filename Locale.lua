-- SellThatStuff - texts (English, then French)
local _, ns = ...

local L = {
  TAB = "SellThatStuff",
  SCAN = "Rescan",
  SCANNING = "Searching the auction house: %d / %d",
  DONE = "%d of %d items are worth more here than at the vendor.",
  NOTHING = "Nothing in your bags can be sold here.",
  POST = "Post",
  CONFIRM = "Confirm",
  POSTED = "Posted",
  WAIT = "One moment, the auction house is busy. Click again.",
  POST_FAILED = "Couldn't post:",
  DURATION = "Duration:",
  MIN_GAIN = "Minimum gain:",
  TIP_MIN_GAIN = "Auctions whose total gain over the vendor is below this aren't offered.",
  COL_ITEM = "Item", COL_QTY = "Qty", COL_AH = "AH (each)", COL_EACH = "Gain (each)",
  COL_TOTAL = "Total gain", COL_DEPOSIT = "Deposit",
  SORT = "Sort by gain",
  TIP_EACH = "For each one sold here instead of at the vendor: the auction house price after its 5% cut, minus the vendor price.",
  NO_PRICE = "none for sale",
  NO_ANSWER = "no answer",
  TIP_GAIN = "For the whole quantity, if it all sells: compared with selling it to the vendor, after the auction house's 5% cut.",
  TIP_DEPOSIT = "Paid when you post. You get it back if it sells, you lose it if it doesn't.",
}

if GetLocale() == "frFR" then
  L.TAB = "SellThatStuff"
  L.SCAN = "Rescanner"
  L.SCANNING = "Recherche à l'hôtel des ventes : %d / %d"
  L.DONE = "%d objets sur %d valent plus ici que chez le marchand."
  L.NOTHING = "Rien dans vos sacs ne peut être vendu ici."
  L.POST = "Vendre"
  L.CONFIRM = "Confirmer"
  L.POSTED = "En vente"
  L.WAIT = "Un instant, l'hôtel des ventes est occupé. Cliquez à nouveau."
  L.POST_FAILED = "Mise en vente impossible :"
  L.DURATION = "Durée :"
  L.MIN_GAIN = "Gain minimum :"
  L.TIP_MIN_GAIN = "Les ventes dont le gain total par rapport au marchand est inférieur à ce montant ne sont pas proposées."
  L.COL_ITEM, L.COL_QTY, L.COL_AH, L.COL_EACH = "Objet", "Qté", "HV (l'unité)", "Gain (l'unité)"
  L.COL_TOTAL, L.COL_DEPOSIT = "Gain total", "Dépôt"
  L.SORT = "Trier par gain"
  L.TIP_EACH = "Pour chaque unité vendue ici plutôt qu'au marchand : le prix de l'hôtel des ventes après sa commission de 5 %, moins le prix du marchand."
  L.NO_PRICE = "aucun en vente"
  L.NO_ANSWER = "pas de réponse"
  L.TIP_GAIN = "Pour toute la quantité, si tout se vend : par rapport à une vente au marchand, après la commission de 5 % de l'hôtel des ventes."
  L.TIP_DEPOSIT = "Payé à la mise en vente. Rendu si l'objet se vend, perdu sinon."
end

ns.L = L
