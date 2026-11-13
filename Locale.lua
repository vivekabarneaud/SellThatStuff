-- SellThatStuff - texts (English, then French)
local _, ns = ...

local L = {
  TAB = "SellThatStuff",
  SCAN = "Scan my bags",
  HINT = "Scan your bags to see what's worth more here than at the vendor.",
  SCANNING = "Searching the auction house: %d / %d",
  DONE = "%d of %d items are worth more here than at the vendor.",
  NOTHING = "Nothing in your bags can be sold here.",
  READONLY = "Read-only for now: nothing is posted.",
  COL_ITEM = "Item", COL_QTY = "Qty", COL_AH = "AH (each)", COL_VENDOR = "Vendor (each)",
  COL_GAIN = "Gain if sold", COL_DEPOSIT = "Deposit",
  NO_PRICE = "none for sale",
  NO_ANSWER = "no answer",
  TIP_GAIN = "If everything sells at this price: what you get after the auction house's 5% cut, minus what the vendor would pay you.",
  TIP_DEPOSIT = "Paid when you post. You get it back if it sells, you lose it if it doesn't.",
}

if GetLocale() == "frFR" then
  L.TAB = "SellThatStuff"
  L.SCAN = "Scanner mes sacs"
  L.HINT = "Scannez vos sacs pour voir ce qui vaut plus ici que chez le marchand."
  L.SCANNING = "Recherche à l'hôtel des ventes : %d / %d"
  L.DONE = "%d objets sur %d valent plus ici que chez le marchand."
  L.NOTHING = "Rien dans vos sacs ne peut être vendu ici."
  L.READONLY = "Lecture seule pour l'instant : rien n'est mis en vente."
  L.COL_ITEM, L.COL_QTY, L.COL_AH, L.COL_VENDOR = "Objet", "Qté", "HV (l'unité)", "Marchand (l'unité)"
  L.COL_GAIN, L.COL_DEPOSIT = "Gain si vendu", "Dépôt"
  L.NO_PRICE = "aucun en vente"
  L.NO_ANSWER = "pas de réponse"
  L.TIP_GAIN = "Si tout se vend à ce prix : ce que vous touchez après la commission de 5 % de l'hôtel des ventes, moins ce que le marchand vous en donnerait."
  L.TIP_DEPOSIT = "Payé à la mise en vente. Rendu si l'objet se vend, perdu sinon."
end

ns.L = L
