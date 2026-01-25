#
# dicom_io.py
# TotalSegmentator
#
# Provides DICOM I/O helpers and conversions to and from NIfTI plus RT Struct export utilities.
#
# Thales Matheus Mendonça Santos - November 2025
#

"""Operacoes de leitura e escrita de DICOM, alem de conversoes para NIfTI."""

import os
import sys
import time
import shutil
import zipfile
from pathlib import Path
import subprocess
import platform

from tqdm import tqdm
import numpy as np
import nibabel as nib
import dicom2nifti

from totalsegmentator.config import get_weights_dir
from nibabel.orientations import (
    axcodes2ornt,
    io_orientation,
    ornt_transform,
    apply_orientation,
)



def command_exists(command):
    return shutil.which(command) is not None


def download_dcm2niix():
    import urllib.request
    print("  Downloading dcm2niix...")

    if platform.system() == "Windows":
        # url = "https://github.com/rordenlab/dcm2niix/releases/latest/download/dcm2niix_win.zip"
        url = "https://github.com/rordenlab/dcm2niix/releases/download/v1.0.20230411/dcm2niix_win.zip"
    elif platform.system() == "Darwin":  # Mac
        # raise ValueError("For MacOS automatic installation of dcm2niix not possible. Install it manually.")
        if platform.machine().startswith("arm") or platform.machine().startswith("aarch"):  # arm
            # url = "https://github.com/rordenlab/dcm2niix/releases/latest/download/macos_dcm2niix.pkg"
            url = "https://github.com/rordenlab/dcm2niix/releases/download/v1.0.20230411/dcm2niix_macos.zip"
        else:  # intel
            # unclear if this is the right link (is the same as for arm)
            # url = "https://github.com/rordenlab/dcm2niix/releases/latest/download/macos_dcm2niix.pkg"
            url = "https://github.com/rordenlab/dcm2niix/releases/download/v1.0.20230411/dcm2niix_macos.zip"
    elif platform.system() == "Linux":
        # url = "https://github.com/rordenlab/dcm2niix/releases/latest/download/dcm2niix_lnx.zip"
        url = "https://github.com/rordenlab/dcm2niix/releases/download/v1.0.20230411/dcm2niix_lnx.zip"
    else:
        raise ValueError("Unknown operating system. Can not download the right version of dcm2niix.")

    config_dir = get_weights_dir()

    urllib.request.urlretrieve(url, config_dir / "dcm2niix.zip")
    with zipfile.ZipFile(config_dir / "dcm2niix.zip", 'r') as zip_ref:
        zip_ref.extractall(config_dir)

    # Give execution permission to the script
    if platform.system() == "Windows":
        os.chmod(config_dir / "dcm2niix.exe", 0o755)
    else:
        os.chmod(config_dir / "dcm2niix", 0o755)

    # Clean up
    if (config_dir / "dcm2niix.zip").exists():
        os.remove(config_dir / "dcm2niix.zip")
    if (config_dir / "dcm2niibatch").exists():
        os.remove(config_dir / "dcm2niibatch")


def dcm_to_nifti_LEGACY(input_path, output_path, verbose=False):
    """
    Uses dcm2niix (does not properly work on windows)

    input_path: a directory of dicom slices
    output_path: a nifti file path
    """
    verbose_str = "" if verbose else "> /dev/null"

    config_dir = get_weights_dir()

    if command_exists("dcm2niix"):
        dcm2niix = "dcm2niix"
    else:
        if platform.system() == "Windows":
            dcm2niix = config_dir / "dcm2niix.exe"
        else:
            dcm2niix = config_dir / "dcm2niix"
        if not dcm2niix.exists():
            download_dcm2niix()

    subprocess.call(f"\"{dcm2niix}\" -o {output_path.parent} -z y -f {output_path.name[:-7]} {input_path} {verbose_str}", shell=True)

    if not output_path.exists():
        print(f"Content of dcm2niix output folder ({output_path.parent}):")
        print(list(output_path.parent.glob("*")))
        raise ValueError("dcm2niix failed to convert dicom to nifti.")

    nii_files = list(output_path.parent.glob("*.nii.gz"))

    if len(nii_files) > 1:
        print("WARNING: Dicom to nifti resulted in several nifti files. Skipping files which contain ROI in filename.")
        for nii_file in nii_files:
            # output file name is "converted_dcm.nii.gz" so if ROI in name, then this can be deleted
            if "ROI" in nii_file.name:
                os.remove(nii_file)
                print(f"Skipped: {nii_file.name}")

    nii_files = list(output_path.parent.glob("*.nii.gz"))

    if len(nii_files) > 1:
        print("WARNING: Dicom to nifti resulted in several nifti files. Only using first one.")
        print([f.name for f in nii_files])
        for nii_file in nii_files[1:]:
            os.remove(nii_file)
        # todo: have to rename first file to not contain any counter which is automatically added by dcm2niix

    os.remove(str(output_path)[:-7] + ".json")


def dcm_to_nifti(input_path, output_path, tmp_dir=None, verbose=False):
    """
    Uses dicom2nifti package (also works on windows)

    input_path: a directory of dicom slices or a zip file of dicom slices or a bytes object of zip file
    output_path: a nifti file path
    tmp_dir: extract zip file to this directory, else to the same directory as the zip file. Needs to be set if input is a zip file.
    """
    # Check if input_path is a zip file and extract it
    if zipfile.is_zipfile(input_path):
        if tmp_dir is None:
            raise ValueError("tmp_dir must be set when input_path is a zip file or bytes object of zip file")
        if verbose: print(f"Extracting zip file: {input_path}")
        extract_dir = os.path.splitext(input_path)[0] if tmp_dir is None else tmp_dir / "extracted_dcm"
        with zipfile.ZipFile(input_path, 'r') as zip_ref:
            zip_ref.extractall(extract_dir)
            input_path = extract_dir
    
    # Convert to nifti
    dicom2nifti.dicom_series_to_nifti(input_path, output_path, reorient_nifti=True)


def _reorient_to_lps(segmentation_img):
    """Return segmentation data aligned to LPS axis codes."""

    current_ornt = io_orientation(segmentation_img.affine)
    target_ornt = axcodes2ornt(("L", "P", "S"))
    transform = ornt_transform(current_ornt, target_ornt)
    data = segmentation_img.get_fdata()
    if data.ndim != 3:
        raise ValueError("Segmentation image must be 3D to convert to RT Struct.")
    reoriented = apply_orientation(data, transform)
    return np.asarray(reoriented)


def save_mask_as_rtstruct(segmentation_img, selected_classes, dcm_reference_file, output_path):
    """Create a volumetric RT Struct from a NIfTI segmentation volume."""

    if not isinstance(segmentation_img, nib.Nifti1Image):
        raise TypeError("segmentation_img must be a nibabel.Nifti1Image instance")

    from rt_utils import RTStructBuilder
    import logging

    logging.basicConfig(level=logging.WARNING)  # avoid messages from rt_utils

    # Align segmentation to LPS (DICOM) orientation and reorder axes: (Slices, Rows, Columns)
    lps_volume = _reorient_to_lps(segmentation_img)
    slices_first = np.transpose(lps_volume, (2, 1, 0))

    rtstruct = RTStructBuilder.create_new(dicom_series_path=dcm_reference_file)

    for class_idx, class_name in tqdm(selected_classes.items()):
        mask = slices_first == class_idx
        if not np.any(mask):
            continue

        rtstruct.add_roi(
            mask=np.ascontiguousarray(mask.astype(np.uint8)),
            name=class_name,
        )

    rtstruct.save(str(output_path))