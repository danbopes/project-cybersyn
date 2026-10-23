#!/bin/bash
# lab.sh with the installed factorio-charts zip loaded (lab.sh passes no --extra), so the Utilization chart checks of
# 39_analytics_test.lua run instead of skipping: LAB=tests/lab/lab-charts.sh tests/lab/run.sh <scratch> <port>.
export SAVETOOL_SCRATCH="$1"; shift
DEV_ON='{"cybersyn-manager-dev-interface": true}'
export CYBLAB_STARTUP="${CYBLAB_STARTUP-$DEV_ON}"
DOCS=/home/daniel/factorio/manager-facelift
cd /home/daniel/factorio/cs2-migration || exit 1
case "$1" in
  start)
    shift
    MOD="$1"; PORT="$2"; SAVE="${3:-layout}"
    case "$SAVE" in
      layout) SAVE="$DOCS/saves/layout-small.zip" ;;
    esac
    exec python3 -I lab20.py start "$SAVE" --mod "cybersyn=$MOD" --mod "aitest=$DOCS/harness/aitest-2.0" --extra factorio-charts --port "$PORT" --game-port "$(( PORT + 7000 ))" ;;
  *) exec python3 -I lab20.py "$@" ;;
esac
