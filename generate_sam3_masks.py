"""
SAM3-based per-frame nadir mask generator (Ultralytics).

Uses SAM3SemanticPredictor with a text prompt ("green suit") to segment
the operator's garment per frame, producing COLMAP-convention masks.

Prerequisites on the pod:
  pip install -U ultralytics
  pip install git+https://github.com/ultralytics/CLIP.git  (after uninstalling clip)
  sam3.pt downloaded from https://huggingface.co/facebook/sam3
  bpe_simple_vocab_16e6.txt.gz (downloaded automatically by this script if not present)

Usage:
  python generate_sam3_masks.py <frames_folder> <masks_folder> <run_label>
  python generate_sam3_masks.py <frames_folder> <masks_folder> <run_label> --checkpoint /path/to/sam3.pt
  python generate_sam3_masks.py <frames_folder> <masks_folder> <run_label> --prompt "green suit"
"""

import os
import sys
import glob
import json
import argparse
import time
from datetime import datetime
import numpy as np
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("frames_folder")
parser.add_argument("masks_folder")
parser.add_argument("run_label")
parser.add_argument("--checkpoint", default="/root/sam3.pt")
parser.add_argument("--prompt", default="green suit")
parser.add_argument("--conf", type=float, default=0.25)
args = parser.parse_args()

os.makedirs(args.masks_folder, exist_ok=True)

# --- Verify checkpoint ---
if not os.path.exists(args.checkpoint):
    print(f"ERROR: SAM3 checkpoint not found at '{args.checkpoint}'")
    sys.exit(1)

# --- Load SAM3 ---
print(f"Loading SAM3 from {args.checkpoint}...")
try:
    from ultralytics.models.sam import SAM3SemanticPredictor
    overrides = dict(
        conf=args.conf,
        task="segment",
        mode="predict",
        model=args.checkpoint,
        quantize=16,  # FP16 for faster inference + lower VRAM
    )
    predictor = SAM3SemanticPredictor(overrides=overrides)
    print(f"SAM3 loaded. Prompt: '{args.prompt}', confidence: {args.conf}")
except ImportError as e:
    print(f"ERROR: Could not import SAM3SemanticPredictor: {e}")
    print("Run: pip install -U ultralytics")
    sys.exit(1)
except Exception as e:
    print(f"ERROR loading SAM3: {e}")
    if "SimpleTokenizer" in str(e):
        print("Run: pip uninstall clip -y && pip install git+https://github.com/ultralytics/CLIP.git")
    sys.exit(1)

# --- Find frames ---
paths = (sorted(glob.glob(f"{args.frames_folder}/*.jpg")) +
         sorted(glob.glob(f"{args.frames_folder}/*.jpeg")) +
         sorted(glob.glob(f"{args.frames_folder}/*.png")))
if not paths:
    print(f"No images found in {args.frames_folder}")
    sys.exit(1)

print(f"\nFound {len(paths)} frames. Generating SAM3 masks...")

coverage_log = []
start_time = time.time()

for idx, p in enumerate(paths):
    frame_name = os.path.basename(p)
    img_arr = np.array(Image.open(p).convert("RGB"))
    h, w = img_arr.shape[:2]

    try:
        predictor.set_image(p)
        results = predictor(text=[args.prompt])

        garment_mask = np.zeros((h, w), dtype=bool)
        if results and results[0].masks is not None:
            for mask_tensor in results[0].masks.data:
                mask_np = mask_tensor.cpu().numpy().astype(bool)
                if mask_np.shape != (h, w):
                    from PIL import Image as PILImage
                    mask_pil = PILImage.fromarray(mask_np.astype(np.uint8) * 255).resize(
                        (w, h), PILImage.NEAREST)
                    mask_np = np.array(mask_pil) > 0
                garment_mask |= mask_np

        # Bottom-anchor filter - keep only blobs touching the bottom band
        import cv2
        ANCHOR_BAND_PCT = 5
        band_start = int(h * (1 - ANCHOR_BAND_PCT / 100))
        num_labels, labels = cv2.connectedComponents(garment_mask.astype(np.uint8))
        band_labels = set(np.unique(labels[band_start:, :]).tolist()) - {0}
        if band_labels:
            garment_mask = np.isin(labels, list(band_labels))
        else:
            garment_mask = np.zeros((h, w), dtype=bool)

        # Morphological dilation: grow the detected region outward to fill
        # small gaps, white dots, and edge discontinuities in SAM3 output.
        # Validated: DILATE_PCT=1.5 filled gaps cleanly on 5-frame test set.
        # Increase if gaps remain; decrease if mask eats into real room content.
        DILATE_PCT = 1.5
        from scipy import ndimage
        dilate_px = max(1, int(w * DILATE_PCT / 100))
        if garment_mask.any():
            garment_mask = ndimage.binary_dilation(garment_mask, iterations=dilate_px)

        # COLMAP convention: white=keep, black=masked
        colmap_mask = np.where(garment_mask, 0, 255).astype(np.uint8)

    except Exception as e:
        print(f"  WARNING: SAM3 failed on {frame_name}: {e}")
        colmap_mask = np.full((h, w), 255, dtype=np.uint8)
        garment_mask = np.zeros((h, w), dtype=bool)

    mask_path = os.path.join(args.masks_folder, frame_name + ".png")
    Image.fromarray(colmap_mask, mode="L").save(mask_path)

    coverage_pct = garment_mask.mean() * 100
    coverage_log.append(coverage_pct)
    elapsed = time.time() - start_time
    avg_per_frame = elapsed / (idx + 1)
    remaining = avg_per_frame * (len(paths) - idx - 1)
    print(f"  [{idx+1}/{len(paths)}] {frame_name}: {coverage_pct:.1f}% masked  (~{remaining:.0f}s remaining)")

avg_cov = sum(coverage_log) / len(coverage_log)
max_cov = max(coverage_log)
min_cov = min(coverage_log)
total_time = time.time() - start_time

print(f"\nDone. Masks saved to: {args.masks_folder}")
print(f"Coverage - avg: {avg_cov:.1f}%, max: {max_cov:.1f}%, min: {min_cov:.1f}%")
print(f"Total: {total_time:.0f}s ({total_time/len(paths):.1f}s/frame)")

if min_cov < 1.0:
    print("WARNING: some frames have very low coverage - try lowering --conf (e.g. --conf 0.15)")
    print("or switch to point prompts if text prompt isn't finding the garment in distorted nadir view")

metadata = {
    "run_label": args.run_label,
    "generated_at": datetime.now().isoformat(),
    "method": "SAM3 via Ultralytics",
    "checkpoint": args.checkpoint,
    "prompt": args.prompt,
    "confidence_threshold": args.conf,
    "input_folder": os.path.abspath(args.frames_folder),
    "output_folder": os.path.abspath(args.masks_folder),
    "num_frames": len(paths),
    "detected_coverage_avg_pct": round(avg_cov, 2),
    "detected_coverage_max_pct": round(max_cov, 2),
    "detected_coverage_min_pct": round(min_cov, 2),
    "total_time_seconds": round(total_time, 1),
    "seconds_per_frame": round(total_time / len(paths), 1),
}
metadata_path = os.path.join(args.masks_folder, f"{args.run_label}_metadata.json")
with open(metadata_path, "w") as f:
    json.dump(metadata, f, indent=2)
print(f"Metadata: {metadata_path}")
