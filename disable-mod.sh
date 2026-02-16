#!/bin/bash
# disable-mod.sh
# Usage: ./disable-mod.sh sodium nvidium
PACK=$1
MOD=$2
mkdir -p "$PACK/mods-disabled"
mv "$PACK/mods/$MOD.pw.toml" "$PACK/mods-disabled/"
cd "$PACK" && packwiz refresh
echo "Disabled $MOD in $PACK — moved to mods-disabled/"

# enable-mod.sh
# Usage: ./enable-mod.sh sodium nvidium
PACK=$1
MOD=$2
mv "$PACK/mods-disabled/$MOD.pw.toml" "$PACK/mods/"
cd "$PACK" && packwiz refresh
echo "Enabled $MOD in $PACK"