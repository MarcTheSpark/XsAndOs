#!/usr/bin/env python3
"""enable_reapy.py -- one-time reapy setup, run INSIDE Reaper.

Enables reapy's "dist API" so scripts like extract_cues.py can drive Reaper
from an external shell. You only need this once (re-run if you reinstall Reaper
or reapy).

How to run:
  1. Make sure Reaper's Python is configured and can import reapy:
     Options > Preferences > Plug-ins > ReaScript -> enable Python; then
     `pip install python-reapy` into THAT same Python.
  2. In Reaper:  Actions > Show action list >
     "ReaScript: Run reaScript (EEL2 or lua/python)..." -> pick this file.
  3. Restart Reaper.
  4. Test from a terminal (with a project open):
        python -c "import reapy; print(reapy.Project().name)"

(You don't need this at all if you run extract_cues.py itself as a ReaScript
inside Reaper -- the dist API is only for driving it from an external shell.)
"""

import reapy

reapy.configure_reaper()
print("reapy dist API configured. Restart Reaper, then drive it from a shell.")
