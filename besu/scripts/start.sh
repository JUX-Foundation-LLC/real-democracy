#!/bin/bash
# Start Besu validator node

set -e

BESU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$BESU_DIR"

echo "🚀 Starting Besu validator node..."
docker-compose up -d

echo ""
echo "✅ Besu node starting!"
echo ""
echo "View logs:    docker logs -f vote_besu_validator_1"
echo "Check status: curl -X POST http://localhost:8545 \\"
echo "                -H 'Content-Type: application/json' \\"
echo "                -d '{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}'"
