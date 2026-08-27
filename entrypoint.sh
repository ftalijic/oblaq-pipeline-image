#!/usr/bin/env bash

# Resolved from realityscan-cli's own wrapper script (found inside the
# installed .deb): RealityScan lives at this path inside the bundled
# CrossOver/Wine "default" bottle. Override with -e RS_EXE=... if a
# future RealityScan version changes this.
RS_EXE="${RS_EXE:-C:/Program Files/Epic Games/RealityScan/RealityScan.exe}"

# Arbitrary name pairing the primary instance below with its delegate.
# Override with -e CON_NAME=... if running multiple containers that need
# distinct names.
CON_NAME="${CON_NAME:-oblaq-rs-instance}"

# Extra flags for the primary (server) launch. Empty by default.
RS_ARGS="${RS_ARGS:-}"

# Flags for the delegate, which is what actually starts the REST remote
# command server. Override the port/tag per container as needed.
RSREMOTE_ARGS="${RSREMOTE_ARGS:--RsRemoteStartREST http://0.0.0.0:1234 -tag oblaq}"

echo "Starting RealityScan primary instance (CON_NAME=$CON_NAME)..."
/opt/realityscan/bin/wine --start --bottle=default "$RS_EXE" -setInstanceName "$CON_NAME" $RS_ARGS &
pid1=$!

# Per Epic's own docs: RealityScan needs time to load fonts and plugins
# before the delegate can attach — don't shorten this.
sleep 10

echo "Starting RealityScan remote-command delegate..."
/opt/realityscan/bin/wine --start --bottle=default "$RS_EXE" -delegateTo "$CON_NAME" $RSREMOTE_ARGS

wait "$pid1"
