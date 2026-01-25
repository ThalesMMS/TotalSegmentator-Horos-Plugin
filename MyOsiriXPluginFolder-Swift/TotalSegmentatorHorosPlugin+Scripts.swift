//
// TotalSegmentatorHorosPlugin+Scripts.swift
// TotalSegmentator
//

import Cocoa

extension TotalSegmentatorHorosPlugin {
    func prepareBridgeScript(at directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("TotalSegmentatorBridge.py", isDirectory: false)
        let scriptContents = """
import argparse
import json
import subprocess
import sys
import traceback
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Bridge script for the Horos TotalSegmentator plugin")
    parser.add_argument("--config", required=True, help="Path to the configuration JSON file")
    args = parser.parse_args()

    with open(args.config, "r", encoding="utf-8") as handle:
        config = json.load(handle)

    dicom_dir = Path(config["dicom_dir"]).expanduser()
    output_dir = Path(config["output_dir"]).expanduser()
    output_type = config.get("output_type", "dicom")

    output_dir.mkdir(parents=True, exist_ok=True)

    command = [
        sys.executable,
        "-m",
        "totalsegmentator.bin.TotalSegmentator",
        "-i",
        str(dicom_dir),
        "-o",
        str(output_dir),
        "--output_type",
        output_type,
    ]
    command.extend(config.get("totalseg_args", []))

    print("[TotalSegmentatorBridge] Executing: " + " ".join(command), flush=True)

    try:
        result = subprocess.run(command, check=False)
    except Exception:
        print("[TotalSegmentatorBridge] Failed to execute TotalSegmentator:", file=sys.stderr, flush=True)
        traceback.print_exc()
        return 1

    if result.returncode != 0:
        print(f"[TotalSegmentatorBridge] TotalSegmentator exited with status {result.returncode}", file=sys.stderr, flush=True)

    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
"""

        try scriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)

        return scriptURL
    }

    func prepareNiftiConversionScript(at directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("TotalSegmentatorNiftiConversion.py", isDirectory: false)
        let scriptContents = """
import argparse
import json
import sys
from pathlib import Path

import nibabel as nib
import numpy as np

from totalsegmentator.dicom_io import save_mask_as_rtstruct
from totalsegmentator.nifti_ext_header import load_multilabel_nifti
from totalsegmentator.map_to_binary import class_map


def log(message):
    print(message, file=sys.stderr, flush=True)


def normalize_name(value):
    return value.strip().lower().replace(" ", "_")


def strip_extension(path):
    name = path.name
    if name.lower().endswith(".nii.gz"):
        return name[:-7]
    if name.lower().endswith(".nii"):
        return name[:-4]
    return name


def find_multilabel_file(base):
    candidates = [
        base / "segmentations.nii.gz",
        base / "segmentations.nii",
        base / "totalsegmentator.nii.gz",
        base / "totalseg.nii.gz",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    for candidate in sorted(base.glob("*.nii.gz")):
        if "seg" in candidate.name.lower():
            return candidate
    for candidate in sorted(base.glob("*.nii")):
        if "seg" in candidate.name.lower():
            return candidate
    return None


def gather_binary_masks(base):
    mask_dir = base / "segmentations"
    candidates = []
    if mask_dir.is_dir():
        candidates.extend(sorted(mask_dir.glob("*.nii")))
        candidates.extend(sorted(mask_dir.glob("*.nii.gz")))
    candidates.extend(sorted(base.glob("*.nii")))
    candidates.extend(sorted(base.glob("*.nii.gz")))

    masks = []
    seen = set()
    for path in candidates:
        name = path.name.lower()
        if path in seen:
            continue
        if "segmentations" in name and path.parent == base:
            continue
        if name.endswith(".nii") or name.endswith(".nii.gz"):
            if "image" in name and "seg" not in name:
                continue
            masks.append(path)
            seen.add(path)
    return masks


def build_multilabel_from_masks(paths):
    if not paths:
        return None
    first_img = nib.load(str(paths[0]))
    data = np.zeros(first_img.shape, dtype=np.uint16)
    mapping = {}
    index = 1
    for path in paths:
        img = nib.load(str(path))
        arr = img.get_fdata()
        if np.any(arr):
            mapping[index] = strip_extension(path)
            data[arr > 0.5] = index
            index += 1
    if not mapping:
        return None
    new_header = first_img.header.copy()
    new_header.set_data_dtype(np.uint16)
    nifti_img = nib.Nifti1Image(data.astype(np.uint16), first_img.affine, new_header)
    return nifti_img, mapping


def load_segmentation(base, task_name):
    multi = find_multilabel_file(base)
    if multi:
        img = nib.load(str(multi))
        data = img.get_fdata().astype(np.uint16)
        try:
            _, label_map = load_multilabel_nifti(img)
            mapping = {int(k): str(v) for k, v in label_map.items()}
        except Exception:
            if task_name and task_name in class_map:
                mapping = {int(k): str(v) for k, v in class_map[task_name].items()}
            else:
                labels = [int(v) for v in np.unique(data) if int(v) != 0]
                mapping = {label: "Label_{}".format(label) for label in labels}
        header = img.header.copy()
        header.set_data_dtype(np.uint16)
        nifti_img = nib.Nifti1Image(data.astype(np.uint16), img.affine, header)
        return nifti_img, mapping

    mask_result = build_multilabel_from_masks(gather_binary_masks(base))
    if mask_result:
        return mask_result

    raise RuntimeError("No NIfTI segmentations were found for conversion.")


def filter_selection(segmentation_img, mapping, selected):
    if not selected:
        return segmentation_img, mapping

    selected_indices = [idx for idx, name in mapping.items() if normalize_name(name) in selected]
    if not selected_indices:
        return segmentation_img, mapping

    selected_indices.sort()
    data = segmentation_img.get_fdata().astype(np.uint16)
    new_data = np.zeros_like(data, dtype=np.uint16)
    new_mapping = {}
    next_index = 1
    for idx in selected_indices:
        new_data[data == idx] = next_index
        new_mapping[next_index] = mapping[idx]
        next_index += 1

    header = segmentation_img.header.copy()
    header.set_data_dtype(np.uint16)
    filtered_img = nib.Nifti1Image(new_data.astype(np.uint16), segmentation_img.affine, header)
    return filtered_img, new_mapping


def main():
    parser = argparse.ArgumentParser(description="Convert TotalSegmentator NIfTI outputs to DICOM artifacts")
    parser.add_argument("--config", required=True)
    args = parser.parse_args()

    with open(args.config, "r", encoding="utf-8") as handle:
        config = json.load(handle)

    nifti_dir = Path(config["nifti_dir"]).expanduser()
    reference_dir = Path(config["reference_dicom_dir"]).expanduser()
    output_dir = Path(config["output_dir"]).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)

    selected = {normalize_name(name) for name in config.get("selected_classes", []) if isinstance(name, str)}
    task_name = config.get("task")

    segmentation_img, mapping = load_segmentation(nifti_dir, task_name)
    if not mapping:
        raise RuntimeError("No segmentation labels available for conversion.")

    segmentation_img, mapping = filter_selection(segmentation_img, mapping, selected)
    if not mapping:
        raise RuntimeError("No segmentation labels remain after applying the class filter.")

    rtstruct_name = config.get("rtstruct_name", "segmentations_rtstruct.dcm")
    rtstruct_path = output_dir / rtstruct_name

    save_mask_as_rtstruct(segmentation_img, mapping, str(reference_dir), str(rtstruct_path))

    result = {
        "rtstruct_paths": [str(rtstruct_path)],
        "dicom_series_directories": []
    }
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        log("[TotalSegmentatorNiftiConversion] {}".format(exc))
        sys.exit(1)
"""

        try scriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)

        return scriptURL
    }

    func writeBridgeConfiguration(
        to directory: URL,
        dicomDirectory: URL,
        outputDirectory: URL,
        outputType: String,
        totalsegmentatorArguments: [String]
    ) throws -> URL {
        let configurationURL = directory.appendingPathComponent("TotalSegmentatorBridgeConfiguration.json", isDirectory: false)

        let payload: [String: Any] = [
            "dicom_dir": dicomDirectory.path,
            "output_dir": outputDirectory.path,
            "output_type": outputType,
            "totalseg_args": totalsegmentatorArguments
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: configurationURL, options: .atomic)

        return configurationURL
    }

    func writeNiftiConversionConfiguration(
        to directory: URL,
        niftiDirectory: URL,
        referenceDirectory: URL,
        outputDirectory: URL,
        preferences: SegmentationPreferences.State
    ) throws -> URL {
        let configurationURL = directory.appendingPathComponent("TotalSegmentatorNiftiConversion.json", isDirectory: false)

        var payload: [String: Any] = [
            "nifti_dir": niftiDirectory.path,
            "reference_dicom_dir": referenceDirectory.path,
            "output_dir": outputDirectory.path,
            "selected_classes": preferences.selectedClassNames,
            "rtstruct_name": "segmentations_rtstruct.dcm"
        ]

        if let task = preferences.task {
            payload["task"] = task
        }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: configurationURL, options: .atomic)

        return configurationURL
    }
}
