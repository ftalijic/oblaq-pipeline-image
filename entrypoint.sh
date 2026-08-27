#!/usr/bin/env bash
/opt/realityscan/bin/wine --start "$RS_EXE" -setInstanceName $CON_NAME $RS_ARGS &
pid1=$!
sleep 10
/opt/realityscan/bin/wine --start "$RS_EXE" -delegateTo $CON_NAME $RSREMOTE_ARGS
wait $pid1
