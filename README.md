# SellThatStuff

Sell what's worth more at the auction house than at the vendor, in a few clicks.
For **World of Warcraft: Forever**. English and French.

> **Beta.** It works, but it's young: if something looks wrong, or you have an idea, tell us
> on Discord: https://discord.gg/5bgAnccyHj

## What it does

Open the auction house and click the **SellThatStuff** tab at the bottom:

- It looks up every item in your bags at the auction house, one after the other.
- Each row shows the cheapest price, your **gain per unit** compared with the vendor
  (after the auction house's 5% cut), the **total gain**, and the **deposit**.
- Click **Post** on the rows you want: one click, one auction, at the cheapest price.
  You can post as soon as a row's price is in, without waiting for the whole scan.
- Choose the **quantity** on each row (all of it by default).
- At the bottom: a **minimum gain** (anything that gains less isn't offered) and the
  **auction duration**. Both are saved.

Never offered: grey items, soulbound items, quest items. Items the vendor won't buy (a
campfire kit...) count as vendor price 0.

The deposit is paid when you post and given back if the item sells.

## Install

Copy the `SellThatStuff` folder into `World of Warcraft\_forever_\Interface\AddOns\`,
then restart the game.

## Commands

| Command | |
|---|---|
| `/sts` | a reminder of how it works |
| `/sts probe` | at an auction house: a test of what the auction house offers addons (for bug reports) |

## License

MIT: you're free to reuse and adapt this addon, as long as you keep the copyright notice
(see `LICENSE`).
