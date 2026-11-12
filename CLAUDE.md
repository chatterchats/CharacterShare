# CharacterShare

@docs/agent-rules.md

Read README.md first: what the mod does, its layout and how it's tested.

## Rules for this repo

- The ZC1 format is frozen: never reorder, remove, repurpose or append codebook entries, tags or
  tables. New assets use the raw `PrimaryAssetId` fallback; anything else needs a new generation.
- Validate a whole code before changing anything; an import never applies partially.
- Check UObjects with `IsValid()` before `GetClass` or any property: an invalid wrapper crashed
  the game while the Databank opened (1.0.4).
- Don't use `NotifyOnNewObject` for Databank discovery during Blueprint or WidgetTree
  construction; keep the activation probe.
- LuaJIT can't parse the codec's Lua 5.3 bit operators, so the bootstrap test stubs the codec.
