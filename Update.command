#!/bin/bash
# ============================================================================
# Update.command  --  double-click (on a Mac) to download the latest version
# of the piece. It just runs "git pull" in this folder and shows the result.
# (On macOS a .command file opens in Terminal and runs when double-clicked;
#  a plain .sh would only open in a text editor.)
# ============================================================================

# Work in the folder this file lives in (the repo), wherever it was put.
cd "$(dirname "$0")" || exit 1

echo "Updating \"Xs and Os\"..."
echo "Folder: $(pwd)"
echo

git pull
status=$?

echo
if [ "$status" -eq 0 ]; then
    echo "✅  Up to date. You can close this window."
else
    echo "⚠️  Update failed (see the messages above). Send Marc a screenshot."
fi
echo
read -n 1 -s -r -p "Press any key to close this window."
echo
