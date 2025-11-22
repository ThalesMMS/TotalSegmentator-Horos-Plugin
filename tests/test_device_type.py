#
# test_device_type.py
# TotalSegmentator
#
# Tests device detection logic for GPU, CPU, and MPS selection paths.
#
# Thales Matheus Mendonça Santos - November 2025
#

"""Testa deteccao de dispositivo suportado (cpu, gpu ou mps)."""

from totalsegmentator.bin.TotalSegmentator import validate_device_type
import unittest
import argparse
class TestValidateDeviceType(unittest.TestCase):
    def test_valid_inputs(self):
        self.assertEqual(validate_device_type("gpu"), "gpu")
        self.assertEqual(validate_device_type("cpu"), "cpu")
        self.assertEqual(validate_device_type("mps"), "mps")
        self.assertEqual(validate_device_type("gpu:0"), "gpu:0")
        self.assertEqual(validate_device_type("gpu:1"), "gpu:1")

    def test_invalid_inputs(self):
        with self.assertRaises(argparse.ArgumentTypeError):
            validate_device_type("invalid")
        with self.assertRaises(argparse.ArgumentTypeError):
            validate_device_type("gpu:invalid")
        with self.assertRaises(argparse.ArgumentTypeError):
            validate_device_type("gpu:-1")
        with self.assertRaises(argparse.ArgumentTypeError):
            validate_device_type("gpu:3.1415926")
        with self.assertRaises(argparse.ArgumentTypeError):
            validate_device_type("gpu:")


if __name__ == "__main__":
    unittest.main()