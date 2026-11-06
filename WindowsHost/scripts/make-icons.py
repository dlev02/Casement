#!/usr/bin/env python3
"""Regenerate Windows app and themed tray icons from the shared Casement artwork (requires Pillow)."""
from pathlib import Path
import runpy
import sys

generator = Path(__file__).resolve().parents[2] / 'brand' / 'generate-icons.py'
sys.argv = [str(generator), '--windows-only']
runpy.run_path(str(generator), run_name='__main__')
