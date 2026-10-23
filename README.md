# hi, this is peek

a tiny, open-source mac menu bar app that finds any photo or video in your library from a description. type "me on a boat at sunset" or "the red mountain", and it finds it in your photos library. then airdrop it, send it in messages, or share it anywhere.

- free and open source (MIT)
- 100% local. your photos never leave your mac, and there's no account, no cloud and no tracking.
- native swift. the search model runs on your mac's neural engine, so the cpu stays at ~0% even while it indexes.
- fast: searching ~19,000 photos takes about 10 ms.

## download

grab **[Peek.dmg](https://github.com/luiginotmario/peek/releases/latest/download/Peek.dmg)**, open it, drag peek into applications, then click the mosaic in your menu bar. apple silicon, macos 14 or newer.

signed and notarized by apple, so it opens like any other app.

## how it works

1. **index once.** peek reads your photos library and turns every photo into a list of 768 numbers that describe what's in it. videos get one of those lists for every two seconds of footage. it uses [siglip 2](https://huggingface.co/google/siglip2-base-patch16-256), an open model from google (apache-2.0), running on the neural engine at ~14 photos a second. new photos are added as they show up; deleted ones drop out.
2. **search instantly.** your words go through the same model and come out as 768 numbers in the same space. the photos whose numbers sit closest to yours are the best matches, and for videos peek remembers the moment. it's one matrix multiply over the whole library.
3. **filter with what photos already knows:** date, place, favorites, and the kind of shot (live photo, portrait, panorama, screenshot, video).

## good to know

- the only network traffic is apple's photos service fetching your own photos from icloud, when a thumbnail or the original isn't on this mac yet. peek itself has no networking code.
- "me" doesn't work yet. siglip knows "a guy and a girl", not who you are. a pick-your-face step is next.
- videos kept only in icloud are searched by their poster frame; videos on this mac get a frame every two seconds.

the index lives in `~/Library/Application Support/Peek/Index`, about 1.5 KB per photo.

## if you wanna make an addition + pr, or just wanna remix it for yourself, go for it

you need macos 14+ and xcode 16+.

convert the model once. this is the only step that uses python, and only on your machine; the app never runs it:

```
uv venv && uv pip install "torch==2.7.0" "transformers>=4.49,<5" "numpy<2.3" coremltools sentencepiece protobuf pillow
.venv/bin/python scripts/convert-model.py --out models
```

then build and try it:

```
./scripts/build.sh                                   # → build/Peek.app
./scripts/peek.sh index                              # asks for photos access, then indexes
./scripts/peek.sh search a yellow boat on the ocean
./scripts/peek.sh search sunset --sheet /tmp/sunset.jpg   # the results as one image
```

make changes on a pr and i'll build a new version :)

## how it's built

```
Sources/PeekCore   swift   photos library, the two siglip encoders and the index
Sources/Peek       swift   the menu bar panel (swiftui + appkit), plus terminal commands for testing
scripts/           python  convert-model.py turns siglip 2 into core ml, once
```

the image half of the model (88 MB, 8-bit) only loads while indexing. the text half (270 MB) only loads while you search. both match the original pytorch model at 0.99+ similarity.

## license

[MIT](LICENSE) — made by [@giginotmario](https://x.com/giginotmario). the siglip 2 weights are apache-2.0, © google.
