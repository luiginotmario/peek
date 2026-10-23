# contributing

thanks for wanting to help. peek stays useful by staying small, so here's the deal:

**yes please**
- better search: smarter ranking, filters, video moments
- making indexing faster or lighter
- bug fixes

**probably not**
- accounts, cloud sync, anything that sends photos off the mac

## getting set up

```
./scripts/build.sh                 # builds build/Peek.app (convert the model first, see the readme)
./scripts/peek.sh index            # index your library
./scripts/peek.sh search <query>   # try a search
```

- the engine is `Sources/PeekCore`: `Library` reads photos, `Indexer` embeds them, `Index` stores and searches.
- the app is `Sources/Peek`: swift 6, main-actor by default. swift code follows [write-swift](https://github.com/emilkowalski/skills/blob/main/skills/write-swift/SKILL.md).
- keep it light. if a change adds a heavy dependency or something that runs in the background, say why in the pr.

open a pr with what you changed and how you tested it. small prs get merged fastest.
