# Mesen scripts for Final Fantasy 1 (NES, USA)

Lua scripts for the Mesen emulator that hook into Final Fantasy 1 to read NPC dialogue, identify who is speaking, and (work in progress) let a local LLM rewrite what they say.

## Scripts

### Dialog capture (`intercept_dialog/intercept_dialog.lua`)

Intercepts the text the game displays and prints it to the Mesen script console.

### Dialog capture with IDs (`intercept_dialog/intercept_dialog_with_id.lua`)

Same as above, and also reports where the text comes from: the current map ID and the ID of the NPC speaking.

### AI (`ai/run.lua`)

Uses the map ID and character ID to look up the NPC in `ai/prompts.lua`. When a configured NPC talks:

1. The original dialog tiles are blanked as the game draws them, and the full original text is captured.
2. A prompt is built from the general prompt, the character prompt and the original text, then sent to a local LLM.
3. The LLM answer is written over the dialog box as in-game text: the blanked
   tiles are filled with the answer, and each line can extend over the blank
   tiles that follow it.

Only NPCs listed in `prompts.lua` and standing next to the player are affected. Other dialogs are left untouched.

## Configuration

`ai/prompts.lua` is a Lua file returning a table:

    return {
      -- Sent every time, before the character prompt and the original text
      general = [[You are an NPC in the NES game Final Fantasy 1. ...]],

      -- npcs[map id][character id] = "character prompt"
      npcs = {
        [0x00] = {
          [0x50] = "A citizen of Coneria, proud of the town and cheerful.",
        },
      },
    }

Map and character IDs are the ones printed in the console (`KEY: 00:50` is map `0x00`, character `0x50`). Talk to an NPC with the capture script to find its IDs.

## Usage

Run the script from the repository root by passing it after the path to your ROM:

    Mesen "/path/to/Final_Fantasy_(USA).zip" ai/run.lua

The AI script looks for `prompts.lua` in this order:

1. next to the script, then Mesen's script data folder (`~/.config/Mesen2/LuaScriptData/run/`)
2. the path in the `FF1_PROMPTS` environment variable
3. `$PWD/ai/prompts.lua`, so run Mesen from the repository root

The console prints the path it loaded, or every path it tried if none was found.

## Requirements

The AI script reads `prompts.lua` from disk and will talk to a local LLM, so it needs I/O and network access. Enable both in Mesen:

Script > Settings > Script Window > Restrictions

* Allow access to I/O and OS functions
* Allow network access