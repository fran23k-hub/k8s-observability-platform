#!/bin/bash

PORTS=(3000 5051 8200 9090 9093)

echo "Cleaning up ports..."

for PORT in "${PORTS[@]}"; do
    PID=$(lsof -ti tcp:$PORT)
    if [ ! -z "$PID" ]; then
        echo "Killing process on port $PORT (PID: $PID)"
        kill -9 $PID
    else
        echo "Port $PORT is free"
    fi
done

echo "Done."
