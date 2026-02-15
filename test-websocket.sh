#!/bin/bash

echo "Testing Cok WebSocket Client"
echo "=============================="
echo ""

# Kill any existing server
echo "Cleaning up any existing servers..."
lsof -ti:8080,8081 | xargs kill -9 2>/dev/null
sleep 1

# Start server in background
echo "Starting server..."
HTTP_PORT=8080 WS_PORT=8081 BASE_DOMAIN=localhost API_KEY_SECRET=test-secret-key-minimum-32-characters MAX_TUNNELS=10 .build/release/cok-server > /tmp/cok-server.log 2>&1 &
SERVER_PID=$!
sleep 2

# Check if server started
if ! ps -p $SERVER_PID > /dev/null; then
    echo "❌ Server failed to start"
    cat /tmp/cok-server.log
    exit 1
fi
echo "✓ Server started (PID: $SERVER_PID)"

# Generate API key
echo "Generating API key..."
API_KEY=$(swift Scripts/generate-api-key.swift test-client test-secret-key-minimum-32-characters 2>&1 | tail -1)
if [ -z "$API_KEY" ]; then
    echo "❌ Failed to generate API key"
    kill $SERVER_PID 2>/dev/null
    exit 1
fi
echo "✓ API Key: $API_KEY"

# Start client
echo ""
echo "Starting client..."
timeout 5 .build/release/cok --port 3000 --subdomain test-client --api-key "$API_KEY" --server ws://localhost:8081 > /tmp/cok-client.log 2>&1 &
CLIENT_PID=$!
sleep 3

# Check if client is still running test  
if ps -p $CLIENT_PID > /dev/null; then
    echo "✓ Client is running (PID: $CLIENT_PID)"
    kill $CLIENT_PID 2>/dev/null
    echo "✓ WebSocket connection successful!"
    RESULT=0
else
    echo "❌ Client crashed"
    echo ""
    echo "Client log:"
    cat /tmp/cok-client.log
    RESULT=1
fi

# Cleanup
kill $SERVER_PID 2>/dev/null
echo ""
echo "Cleanup complete"
exit $RESULT
