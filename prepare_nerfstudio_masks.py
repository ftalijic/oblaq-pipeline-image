"""
Convert COLMAP-convention masks to Nerfstudio-convention.

COLMAP expects: masks/frame_0001.jpg.png (original filename + .png appended)
Nerfstudio expects: masks/frame_0001.png (extension REPLACED, not appended),
                     placed inside the processed dataset folder so its
                     COLMAP dataparser picks them up automatically.

Usage:
  python prepare_nerfstudio_masks.py <colmap_masks_folder> <ns_dataset_folder>
  Example: python prepare_nerfstudio_masks.py /root/dataset/masks /root/ns_dataset

Copies (does not move) masks into <ns_dataset_folder>/masks/ with corrected
filenames. Original COLMAP-convention masks are left untouched.
"""

import sys
import os
import glob
import shutil

if len(sys.argv) < 3:
    print("Usage: python prepare_nerfstudio_masks.py <colmap_masks_folder> <ns_dataset_folder>")
    sys.exit(1)

colmap_masks_dir = sys.argv[1]
ns_dataset_dir = sys.argv[2]
ns_masks_dir = os.path.join(ns_dataset_dir, "masks")

os.makedirs(ns_masks_dir, exist_ok=True)

# Find all COLMAP-convention masks: <original_filename>.png
# e.g. frame_0001.jpg.png -> we want frame_0001.png
mask_paths = sorted(glob.glob(f"{colmap_masks_dir}/*.png"))
mask_paths = [p for p in mask_paths if not os.path.basename(p).endswith("_metadata.json")]

if not mask_paths:
    print(f"No mask files found in {colmap_masks_dir}")
    sys.exit(1)

converted = 0
skipped = 0
for p in mask_paths:
    fname = os.path.basename(p)  # e.g. frame_0001.jpg.png

    # Strip the COLMAP-appended .png, then strip the original extension too,
    # then add back a single .png - this handles frame_0001.jpg.png -> frame_0001.png
    # regardless of what the original image extension was (.jpg, .jpeg, .png)
    if fname.endswith(".png"):
        without_added_png = fname[:-4]  # frame_0001.jpg
        base_name = os.path.splitext(without_added_png)[0]  # frame_0001
        new_fname = base_name + ".png"  # frame_0001.png
    else:
        print(f"  Skipping unexpected filename format: {fname}")
        skipped += 1
        continue

    dest_path = os.path.join(ns_masks_dir, new_fname)
    shutil.copy(p, dest_path)
    converted += 1

print(f"Converted {converted} masks to Nerfstudio convention.")
if skipped:
    print(f"Skipped {skipped} files with unexpected naming.")
print(f"Masks written to: {ns_masks_dir}")
print("Nerfstudio's COLMAP dataparser will pick these up automatically during ns-train.")
