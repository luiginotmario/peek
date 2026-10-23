"""converts google/siglip2-base-patch16-256 into the two core ml models peek ships.

run once, on the maintainer's mac. users never need python:

    uv venv && uv pip install torch transformers coremltools sentencepiece protobuf pillow numpy
    python scripts/convert-model.py --out models

writes models/ImageEncoder.mlpackage, models/TextEncoder.mlpackage,
models/tokenizer/ and models/siglip.json, then checks core ml against pytorch.
"""

import argparse
import json
import shutil
from pathlib import Path

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch
from PIL import Image
from transformers import AutoModel, AutoProcessor

MODEL_ID = "google/siglip2-base-patch16-256"
# the gpu path (mpsgraph) fails to compile the text encoder's 256k-row embedding table, and the
# neural engine is the low-power path anyway, so peek runs both encoders on cpu + neural engine
UNITS = ct.ComputeUnit.CPU_AND_NE
TEXT_LENGTH = 64  # siglip pads every prompt to 64 tokens and was trained without an attention mask


def pooled(output):
    # transformers 5 returns a model output here; 4.x returned the projected tensor itself
    return output if isinstance(output, torch.Tensor) else output.pooler_output


class ImageEncoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, pixels):  # pixels already scaled to [-1, 1] by the core ml image input
        features = pooled(self.model.get_image_features(pixel_values=pixels))
        return torch.nn.functional.normalize(features, dim=-1)


class TextEncoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, ids):
        features = pooled(self.model.get_text_features(input_ids=ids))
        return torch.nn.functional.normalize(features, dim=-1)


def palettize(mlmodel):
    # 8-bit k-means palettes: half of fp16 at 0.99+ cosine to pytorch. plain int8 (below) drops the
    # vision tower to ~0.87, so it only gets the 256-entry palette treatment
    config = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(mode="kmeans", nbits=8))
    return cto.palettize_weights(mlmodel, config)


def quantize(mlmodel):
    # 8-bit linear weights: fine for the text tower (0.997 cosine) and fast on its 256k-token table
    config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric"))
    return cto.linear_quantize_weights(mlmodel, config)


def cosine(a, b):
    a, b = np.asarray(a).ravel(), np.asarray(b).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="models")
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    model = AutoModel.from_pretrained(MODEL_ID, torch_dtype=torch.float32).eval()
    processor = AutoProcessor.from_pretrained(MODEL_ID)
    size = processor.image_processor.size["height"]

    print("→ image encoder")
    image_encoder = ImageEncoder(model).eval()
    example_pixels = torch.zeros(1, 3, size, size)
    traced = torch.jit.trace(image_encoder, example_pixels)
    image_ml = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, size, size), scale=1 / 127.5, bias=[-1, -1, -1],
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
        skip_model_load=True,  # loaded below on the units peek actually uses
    )
    image_ml = palettize(image_ml)
    image_ml.short_description = "SigLIP 2 B/16-256 image encoder, L2-normalized 768-d embedding"
    image_ml.save(out / "ImageEncoder.mlpackage")
    image_ml = ct.models.MLModel(str(out / "ImageEncoder.mlpackage"), compute_units=UNITS)

    print("→ text encoder")
    text_encoder = TextEncoder(model).eval()
    example_ids = torch.zeros(1, TEXT_LENGTH, dtype=torch.int32)
    traced = torch.jit.trace(text_encoder, example_ids)
    text_ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="ids", shape=(1, TEXT_LENGTH), dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
        skip_model_load=True,  # loaded below on the units peek actually uses
    )
    text_ml = quantize(text_ml)
    text_ml.short_description = "SigLIP 2 B/16-256 text encoder, L2-normalized 768-d embedding"
    text_ml.save(out / "TextEncoder.mlpackage")
    text_ml = ct.models.MLModel(str(out / "TextEncoder.mlpackage"), compute_units=UNITS)

    print("→ tokenizer")
    tokenizer_dir = out / "tokenizer"
    shutil.rmtree(tokenizer_dir, ignore_errors=True)
    processor.tokenizer.save_pretrained(tokenizer_dir)

    # the sigmoid head turns a cosine into a match probability: sigmoid(cos * scale + bias)
    meta = {
        "model": MODEL_ID,
        "imageSize": size,
        "textLength": TEXT_LENGTH,
        "dimensions": int(model.config.text_config.projection_size if hasattr(model.config.text_config, "projection_size") else model.config.text_config.hidden_size),
        "logitScale": float(model.logit_scale.exp().item()),
        "logitBias": float(model.logit_bias.item()),
        "padId": int(processor.tokenizer.pad_token_id),
        "lowercase": True,
    }
    (out / "siglip.json").write_text(json.dumps(meta, indent=2))

    print("→ checking core ml against pytorch")
    probe = Image.new("RGB", (size, size))
    probe.paste((230, 190, 40), (0, 0, size // 2, size))  # a yellow-and-blue card, enough to exercise the net
    probe.paste((30, 90, 200), (size // 2, 0, size, size))
    reference_pixels = processor(images=probe, return_tensors="pt")["pixel_values"]
    with torch.no_grad():
        reference_image = image_encoder(reference_pixels).numpy()
    ml_image = image_ml.predict({"image": probe})["embedding"]
    print(f"  image cosine vs pytorch: {cosine(reference_image, ml_image):.4f}")

    prompts = ["a yellow boat on the ocean", "a photo of a dog"]
    for prompt in prompts:
        ids = processor.tokenizer(prompt.lower(), padding="max_length", max_length=TEXT_LENGTH,
                                  truncation=True, return_tensors="np")["input_ids"].astype(np.int32)
        with torch.no_grad():
            reference_text = text_encoder(torch.from_numpy(ids)).numpy()
        ml_text = text_ml.predict({"ids": ids})["embedding"]
        print(f"  text cosine vs pytorch ({prompt!r}): {cosine(reference_text, ml_text):.4f}")
        print(f"    ids: {ids[0][:12].tolist()}…")

    print(f"✓ {out}")


if __name__ == "__main__":
    main()
