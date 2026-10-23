# Peek

Find any photo or video on your Mac by describing it, then AirDrop it, send it in Messages or share it anywhere. Everything runs on your Mac: no account, no cloud, nothing leaves your computer.

> Early days. Right now Peek is a search engine you drive from the terminal; the menu bar panel is next.

## How it works

1. **Index once.** Peek reads your Photos library and turns every photo, and a frame every two seconds of every video, into a 768-number vector with [SigLIP 2](https://huggingface.co/google/siglip2-base-patch16-256) (Apache-2.0), running on the Neural Engine. New photos are added incrementally.
2. **Search instantly.** Your words go through the same model into the same space; the closest vectors are the best matches. One matrix multiply over the whole library.
3. **Filter with metadata.** Date, place, favorites and media type come straight from Photos.

The index lives in `~/Library/Application Support/Peek/Index` (~1.5 KB per photo).

## Build

Requires macOS 14+ and Xcode 16+.

```sh
# once: convert the model (python is only needed here, never at runtime)
uv venv && uv pip install "torch==2.7.0" "transformers>=4.49,<5" "numpy<2.3" coremltools sentencepiece protobuf pillow
.venv/bin/python scripts/convert-model.py --out models

scripts/build.sh                                  # → build/Peek.app
scripts/peek.sh index                             # asks for Photos access, then indexes
scripts/peek.sh search a yellow boat on the ocean
scripts/peek.sh search sunset --sheet /tmp/sunset.jpg   # results as one contact-sheet image
```

## License

MIT. The SigLIP 2 weights are Apache-2.0, © Google.
