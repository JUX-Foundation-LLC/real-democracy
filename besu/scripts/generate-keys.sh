#!/bin/bash
# Generate validator keys for Besu IBFT2 network

set -e

BESU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR_DIR="$BESU_DIR/config/validator1"

echo "🔑 Generating Besu validator keys..."

# Create validator config directory
mkdir -p "$VALIDATOR_DIR"

# Generate random 32-byte hex key (64 hex characters)
NODE_KEY=$(openssl rand -hex 32)
echo "$NODE_KEY" > "$VALIDATOR_DIR/key"

# Extract public key using Besu
docker run --rm \
  -v "$VALIDATOR_DIR:/keys" \
  hyperledger/besu:latest \
  --data-path=/keys \
  public-key export --to=/keys/key.pub

echo "✅ Keys generated at: $VALIDATOR_DIR"
echo ""
echo "Node Key (public): $(cat "$VALIDATOR_DIR/key.pub")"
echo ""
echo "⚠️  IMPORTANT: The private key is at $VALIDATOR_DIR/key"
echo "   Keep this file secure and never commit it to git!"
