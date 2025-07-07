#!/bin/bash

set -e

SCENARIO=${1:-EulerSwapBasic}


function cleanup {
    pkill -P $$
}

trap cleanup EXIT


PORT=${PORT:-8545}
anvil --port $PORT --code-size-limit 100000 &
sleep 1


RPC_URL=http://127.0.0.1:$PORT bash ./deploy-scenario.sh "$SCENARIO"


echo -------------------------------
echo DEVLAND READY
echo SCENARIO = $SCENARIO
echo RPC URL = http://127.0.0.1:$PORT
echo -------------------------------

wait
