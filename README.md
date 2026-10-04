<img src="media/icon.png" alt="HeroHelper" width="96" align="left"/>

## HeroHelper

A simple TBC Classic Anniversary addon that tells Shamans **when** to cast Heroism / Bloodlust on every raid and dungeon boss.

<br clear="left"/>

No more checking the spreadsheet between pulls. No more "wait, was I supposed to lust this one?". A glowing reminder pops up at the right moment. Cast your Heroism/Bloodlust the way you normally do, and keep DPS'ing.

![Reminder button on a boss pull](media/screenshots/screenshot-reminder.png)
*The reminder pops up when it's time to cast. HeroHelper is purely a timing indicator — you cast Heroism / Bloodlust however you already have it bound.*

---

### What it does

- Watches every raid pull and every dungeon boss.
- Pops a glowing reminder at the moment your raid wants Heroism — on the pull, at a specific HP%, when a phase starts, after a set time, or any combination.
- Stays out of your way the rest of the time. Hidden until needed, fades out after the cast.
- Purely a timing indicator — the addon never casts for you, so there's no click-through risk and no combat-lockdown surprises. You trigger Heroism / Bloodlust the way you always do (action bar, keybind, whatever).
- Knows about every boss in **all nine TBC raids** and **every TBC 5-man dungeon**, with researched defaults out of the box.
- Coordinates with **other shamans in your group** so two of you don't waste a Heroism on the same pull.

---

### How to use it

**1. Install.** Drop the `HeroHelper` folder into `Interface/AddOns/`, or grab the latest release from CurseForge.

**2. Position the reminder.** Type `/hh` to open the options.

![Options panel](media/screenshots/screenshot-options-general.png)

- In the **General** tab, choose your sound and (if you raid with another shaman) pick your role: *Primary*, *Secondary*, *Backup*, or *Auto*.
- Type `/hh test` once to show the reminder, drag it where you want it, then `/hh test` again to hide it.

**3. Pick your triggers.** Open the **Bosses** tab.

![Bosses configuration](media/screenshots/screenshot-options-bosses.png)

Each boss has a default trigger that should be sensible for most raids. You can change any of them:

- **Pull** — fires the reminder the moment you engage the boss.
- **HP %** — fires when the boss drops below a chosen HP percentage (good for execute phases).
- **Time** — fires a fixed number of seconds after the pull.
- **Multi** — fires on the *first* of multiple conditions you pick (e.g. *HP 25% or 90 seconds in*).
- **Skip** — don't fire for this boss.
- **Off** — disable the reminder for this boss entirely.

Click **Export** to copy your settings as a share string and send them to the rest of your raid. They click **Import** and you're synced.

**4. Pull a boss.** When the reminder pops, cast Heroism / Bloodlust however you normally do it (action bar, keybind, macro — whatever you already have set up). The addon never casts for you; it just tells you *when*.

---

### Coordinating with other shamans

By default, every HeroHelper-using shaman fires their own reminder. When you want to lock in who Heroes, someone types `/hh roster lock` — that freezes the current roster, announces the resolved order to group chat, and from then on only the elected shaman's reminder fires. If that shaman dies before casting, the reminder automatically jumps to the next-priority alive shaman (Primary > Secondary > Backup).

Each shaman sets their **role** in the General tab before the lock:

- **Primary** — elected first when alive.
- **Secondary** — elected if Primary is dead.
- **Backup** — elected if Primary and Secondary are dead.
- **Auto** — no explicit role; alphabetical tiebreak only.

The player who locked the order, or a group leader/assistant, can type `/hh roster unlock` to go back to everyone firing independently. Locks are shared with the other clients and cleared when you leave the group; everyone needs a version that supports shared locks. `/hh roster` on its own shows the current state — locked or live, roster contents, and the current elected winner.

---

### Slash commands

| Command | What it does |
|---|---|
| `/hh` | Open the options panel |
| `/hh test` | Show / hide the reminder so you can drag it into position |
| `/hh mobtest` | Test the reminder by targeting any mob (fires when it drops below 50% HP) |
| `/hh mobtest pull` | Test the pull-trigger flow on the next mob you engage |
| `/hh lock` / `/hh unlock` | Lock or unlock the reminder in place |
| `/hh reset` | Move the reminder back to screen center |
| `/hh roster` | Show the current multi-shaman roster and whether it's locked |
| `/hh roster lock` | Freeze the hero order, announce it to the group, suppress non-winners |
| `/hh roster unlock` | Release the lock; every shaman fires independently again |
| `/hh debug` | Toggle verbose chat output (for troubleshooting) |

---

### About the cast

HeroHelper never casts Heroism / Bloodlust for you — it's purely a timing reminder. Cast the spell the way you already do: action bar click, keybind, personal macro, whatever. Keeping the cast out of the addon sidesteps all the TBC 2.5.5 combat-lockdown / protected-frame pitfalls (including the click-through bug where clicks under a hidden reminder could fire BL onto raid frames).

---

### Compatibility

- **Game version**: TBC Classic Anniversary (2.5.6)
- **Addon version**: 2.0.2
- Works on its own. Plays nicely with **BigWigs** and **DBM** if you have them.

---

### Acknowledgments

Architecture and visual style are aligned with [FishingKit](https://github.com/klopfer-hello/fishingkit-reworked) — same module layout, same flat dark config theme, same self-contained minimap button pattern.

---

### License

MIT — see [LICENSE](LICENSE).
