# Changelog

What changed in each release of the Eternity suite, newest first. Every addon shares the release's version.

## Unreleased

### Fixed
- Range: out of combat it failed with "table index is nil" on every refresh (the duel and follow distances have no spell).
- Bags: every character showed twice in the gold list (and the total counted them twice) since the game started answering an empty realm name. Eternity now keeps the last realm name seen, and the characters, guild banks and Discs keys saved under the empty realm go back to the real one.

## 0.10.0 (2026-11-20)

### Added
- Range: a new addon that shows your target's distance in yards (e.g. 8-35) as a text you place, colored by zone: melee, dead zone, in range or out of range, each color your choice.
- Minimal: a new addon that hides the parts of the interface you pick (Eternity's, Blizzard's, Zygor, Questie, Spy or any frame by name) and shows them again with one button, a key or `/etmin`, in combat too.
- Bags: a small icon on items saved in one of your equipment sets, with an option to place it in any corner.
- Bags: `/etbags taint` checks what a bag item's click reads, to find the cause of a blocked item use.
- Options: a new layout for the modules' pages, picked in Personalization > General ("Options layout"): cards that fold, two columns, a lighter field per option whose tone you set, a mark and a reset button on the options you changed, and a Basic / Advanced level. The classic layout stays the default.
- Options: in the new layout, a module's preview (Action Bars, Unit Frames) opens in a window beside the options from a button next to the close button.
- Action Bars: "All bars" settings for size, spacing, scale, opacity and when the bars show. Every bar follows them until you change that setting in the bar itself.
- Alerts: a missing buff rule can also warn when the buff has a few seconds left (1 to 600, off by default), with a countdown on its icon. Buffs that don't run out never count.
- Alerts: in General, where the names go (below, above, beside or inside the icon) and their size, the size of the value, the icon border, and the countdown's position (inside or outside the icon), size, color and a border of its own color and size.
- Alerts: each rule can set its own icon size, show or hide its name, glow in its own color, use an icon of its own and turn its countdown off.
- Alerts: rules can have an "up to level" besides "from level": they show only between the two, both included (no limit by default).
- Unit frames: threat (aggro) on every frame: a border or glow, yellow when the unit is about to pull aggro and orange or red once it has it (on enemies, your threat on them). Each frame can switch it off; the look, the colors and the early warning are in General.
- Unit frames: each group member's target beside their frame (off by default): a small health bar with an icon (raid mark, class or portrait), name and percent, with its own size, place and colors. Click it to target that unit.
- Unit frames: raid tanks in a frame of their own (main tanks and assists, or the tank role), each with their target, buffs on, and their own aura filters.
- Alerts: a "Duplicate" button on each rule makes a copy right under it and opens it.
- Auras: more orders for your buffs and the target's debuffs (ending soonest, by name or as they were cast, without putting yours first; important ones first) and a "Reverse order" switch. The game sorts them, so they also work in combat.

### Changed
- Action Bars: the preview shows real buttons with your shape, border, backdrop, shadow and icons, and the bar's opacity.
- Options: sliders update the live preview while you drag them.
- Alerts: the rules belong to the profile, like every other option: each profile has its own list, and a profile copied, exported or imported takes its rules. The rules saved for the whole account are copied into every profile the first time. Profiles keep a module's own data (`Store:GetData`/`SetData`).

### Fixed
- Map: with OpenMap (or MoveAny, Mapster, Leatrix Maps) the world map could no longer be dragged. Eternity now leaves the map's position and scale to that addon and says so once in the chat.
- Minimap: the addon buttons panel opens again with Zygor Guides (it failed with "stack overflow"), and another addon's broken frames no longer stop it.
- Unit frames: the level of NPCs and enemy players is shown in its difficulty color (gray to red) instead of always white.
- Buffs: the messages pointed to `/editmode`, which Forever doesn't have; they now say game menu (Esc) > Edit Mode.

## 0.9.0 (2026-11-14)

### Added
- Bags: choose which sort the Sort button uses: Eternity's (the default), which leaves locked items where they are, or Blizzard's, which is instant.

### Changed
- Bags: the "..." button opens the bags' options. Forgetting characters moves from its menu to a Characters tab there.
- Bags: with Blizzard's sort the padlock is greyed out and the slots' padlocks are hidden (the locks are kept). Clicking the padlock switches to Eternity's sort and starts locking.

## 0.8.0 (2026-11-13)

### Added
- Mail: a new addon with the history of the mail every character sends and receives (`/etmail` or the button by the mailbox), with class-coloured names and item rows, and "Remember the name when sending".
- Bags: the bags open with the personal, warband and guild bank, with options to close both with the bags key and to keep the bags open when walking away.
- Bags: the tooltip of a supply crate lists each material it takes, how many you have and on which characters.
- Bags: what waits in each character's mailbox, and what you mail to your own characters, counts in the item tooltips and the supply crates.
- Bags: the item tooltip shows where each count is (bags, bank, mail, equipped) as a small icon, with an option to keep the words.
- Chat: a copy button on each chat window (and `/etchat copy`) opens its text in a box to select and copy, without colors or icons. Protected lines show as "(protected)". It can be hidden in the options.
- Unit frames: PvP and combat icons on every frame (all but the raid by default): the faction's icon while flagged for PvP, another in free-for-all, and crossed swords while the unit is in combat. Each can be switched off, placed and sized per frame.
- Stats: drag the panel by its title to place it anywhere, and resize it from its corner (the columns fit the width and the rows scroll). It remembers both.
- Stats: a tab to the right of Titles in the character window shows or hides the panel; right-click opens its settings.
- Stats: panel settings over the panel, to check the sections and each stat it shows, with icons to turn them all on or off, and an option to keep one section open at a time.
- Stats: total avoidance in Defense, without and with block.

### Changed
- Automation: "Keep the recipient after sending" moves to the new Mail addon.
- Unit frames: the target of target fades out of range by default, by its own distance from you.
- Options: descriptions no longer show as text. A small "i" beside the title of each page, option, tab and chart shows them in a tooltip.
- Stats: the panel shows two columns and stats at zero by default.

### Fixed
- Unit frames: a target close by is no longer faded when the game hides its group range; out of range goes by a class spell or the follow distance.
- Unit frames: the raid target icon shows when the game gives its index as a secret, centred on the health and power bars.
- Unit frames: a unit without power hides the power bar and gives its room to health.
- Unit frames: the combat and resting icons show again, with the client's own art (resting is animated).
- Bags: using an item from the bags (Hearthstone, a sleeping bag...) with the mouse still on it no longer shows "EternityUI_Bags was forbidden to call UNKNOWN()".
- Stats: the panel shows the same stats in the same format in and out of combat.

## 0.7.0 (2026-11-11)

### Added
- Blacklist: a new addon to keep your own list of players of either faction with the reason for each (`/bl`). Add them from a player's right-click menu or the list window; listed players are flagged in the tooltip, on target and when they join your group.
- Chat: shift-click an item (or any link) while writing in the messenger to put its link there; links in the conversation show their tooltip on mouseover.
- Chat: an option to play the whisper sound even while that conversation is open.

## 0.6.0 (2026-11-10)

### Added
- Objectives: a "This zone only" button beside the tracker's collapse button. One click tracks only the quests of your zone, following you as you travel; another gives your own back.

## 0.5.0 (2026-11-09)

### Added
- Unit frames: the unit's tooltip on mouseover, with an option to show it always, only out of combat or never.

### Fixed
- Chat: an error every time you left combat (since 0.4.0).

## 0.4.0 (2026-11-09)

### Added
- **Unit frames** (new addon): player, pet, target, target of target, focus, group, raid and group pets. Per-frame bars, texts, portraits, icons and colors, incoming heals and shields, range fade, buffs and debuffs with named filters, and a live preview.
- Five fonts: Roboto, Open Sans, Quicksand, Orbitron and Cormorant.
- Your own background image for the options, chat, quests and bags.
- Bags: lock slots so Sort leaves them alone.
- Automation: keep the mail recipient after sending.
- Mover: an Elements panel to choose which handles show, and a Mover button on each module's page.
- Sliders: click the value to type an exact number.
- Chat and Objectives: a lighter background in combat.
- Resources: font option.

### Changed
- Bugs: the Errors tab shows every session by default and remembers your pick.
- Options: the General and Appearance tabs scroll.

### Fixed
- Action bars: an error when giving the micro menu back to Blizzard.

## 0.3.0 (2026-11-09)

### Added
- Resources: number format (short, full or with a thousands separator).

## 0.2.0 (2026-11-09)

### Added
- **Auras** (new addon): your target's debuffs and your own buffs in separate frames, filtered by spell list, also in combat.
- Info bar: bag slots, level progress and durability items, a Content tab to switch and order them, and row layout options.
- Tooltip: spell IDs on buffs and debuffs, plus NPC, currency, mount, pet, toy, achievement and quest IDs.

## 0.1.6 (2026-11-08)

### Added
- **Bugs** (new addon): collects Lua errors, warnings and blocked actions to read, copy and clear (`/etbugs`).
- Bags: other characters' bags, banks and gold, and the saved guild bank.
- Info bar: a Performance tab showing where FPS go.
- Resources: background, border, corners and text look options.
- Mover: the toolbar can be dragged.

### Fixed
- Alerts: every class shows in the class filter.
- Objectives: the tracker no longer jumps between two spots. Moving it with the Mover is now off by default.
- Action bars: no "after combat" notice for pet and form changes.

## 0.1.5 (2026-11-07)

### Added
- **Resources** (new addon): power bar that follows druid forms, combo points and druid mana.
- **Swing timer** (new addon): split out of Cast bars.
- Options: a search box for settings and pages.
- Bags: a keyring check box.

### Changed
- Bags: Esc closes the bags and bank. Right click on the background no longer opens the options.

### Fixed
- Options: an error in the profile share box.

## 0.1.4 (2026-11-06)

### Added
- **Loot** (new addon): loot window, loot history (`/etloot`) and movable roll windows.
- The quest tracker can be placed with the Mover.

### Fixed
- Mover: the Edit Mode button works.

## 0.1.3 (2026-11-06)

### Fixed
- Minimap: collected buttons respond to clicks again.

## 0.1.2 (2026-11-06)

### Added
- **Buffs** (new addon): Blizzard's buff and debuff frames in the Mover.
- **Portraits** (new addon): theme class portraits over Blizzard's player, target, focus and party portraits.
- Five themes: Bubblegum, Sakura, Fuchsia, Cotton Candy and Borahae, with optional wallpapers.
- Mover: scaling.

### Changed
- Bags, chat, minimap, map, quests, action bars and alerts: assorted improvements.
- The options window opens over Blizzard's options instead of closing them.

### Fixed
- Map: the quest details parchment is kept.

## 0.1.1 (2026-11-05)

- Maintenance release, no player-facing changes.

## 0.1.0 (2026-11-05)

- First release: the core, options and Mover, plus Action bars, Alerts, Automation, Bags, Cast bars, Chat, Discs, Experience, Info bar, Map, Minimap, Objectives, Stats and Tooltip.
