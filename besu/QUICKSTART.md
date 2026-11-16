# Besu Private Network - Quick Start Guide

## 🎉 Your Besu Node is Running!

**Network Details:**
- **Chain ID**: 1337 (matches Hardhat for compatibility)
- **Consensus**: IBFT 2.0 (Byzantine fault tolerant)
- **JSON-RPC (HTTP)**: http://localhost:8545
- **JSON-RPC (WS)**: ws://localhost:8546
- **Block Time**: 4 seconds
- **Validator Address**: 0x04bf808983c76374bf0e743f2e492da646dff886

---

## ✅ What's Working

- ✅ Single IBFT2 validator node running
- ✅ JSON-RPC endpoint responding
- ✅ Genesis block with 200 ETH pre-funded account
- ✅ Persistent blockchain data (survives container restarts)
- ✅ Zero gas price (free transactions for testing)

---

## 🚀 Quick Commands

**Start Besu:**
```bash
cd <repo-root>/besu
docker-compose up -d
```

**Stop Besu:**
```bash
docker-compose down
```

**View logs:**
```bash
docker logs -f vote_besu_validator_1
```

**Check status:**
```bash
curl -X POST http://localhost:8545 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

---

## 🔒 LAN Access (No Public Internet)

If you want other machines on your LAN to access Besu without opening it to the public internet:

1. Keep the container ports bound locally (as-is in docker-compose).
2. Add your LAN host/IP to `host-allowlist` and CORS entries in [vote/besu/config/validator1/config.toml](vote/besu/config/validator1/config.toml).
3. Avoid enabling `ADMIN` APIs over HTTP/WS.

---

## 🔑 Pre-funded Accounts

The genesis file includes one account with 200 ETH for testing:

**Address:** `0xfe3b557e8fb62b89f4916b721be55ceb828dbd73`
**Private Key:** `<YOUR_DEV_SIGNER_PRIVATE_KEY — see .env.example>`
**Balance:** 200 ETH

⚠️ **This is a test account only!** Never use this private key in production.

---

## 📊 Next Steps

### 1. Deploy Smart Contracts

Update your Hardhat config to point to Besu:

```javascript
// hardhat.config.js
networks: {
  besu: {
    url: "http://localhost:8545",
    chainId: 1337,
    accounts: ["<YOUR_DEV_SIGNER_PRIVATE_KEY — see .env.example>"]
  }
}
```

Deploy:
```bash
cd <repo-root>/smc
npx hardhat run scripts/deploy.js --network besu
```

### 2. Update Backend Configuration

Point your backend to Besu instead of Hardhat:

```bash
# vote/backend/.env
BLOCKCHAIN_RPC_URL=http://besu:8545  # For Docker
# OR
BLOCKCHAIN_RPC_URL=http://localhost:8545  # For local dev
```

### 3. Test Contract Deployment

Test deploying ProposalManager.sol to ensure compatibility.

---

## 🔧 Troubleshooting

### Besu won't start

**Check logs:**
```bash
docker logs vote_besu_validator_1
```

**Common issues:**
- Port 8545 already in use → Check with `netstat -an | grep 8545`
- Genesis file corrupted → Regenerate with `besu rlp encode`
- Data directory corrupted → Delete `data/` and restart

### RPC connection refused

**Verify container is running:**
```bash
docker ps | grep besu
```

**Check RPC is enabled:**
```bash
docker logs vote_besu_validator_1 | grep "JSON-RPC service started"
```

### Blocks not mining

Single-validator IBFT2 networks don't mine blocks until transactions are submitted. This is expected behavior.

---

## 📚 Resources

**Official Documentation:**
- [Besu IBFT2 Consensus](https://besu.hyperledger.org/private-networks/how-to/configure/consensus/ibft)
- [Genesis File Format](https://besu.hyperledger.org/public-networks/concepts/genesis-file)

**Project Context:**
- [vote/besu/README.md](README.md) - Full architecture documentation

---

**Built for INVENTIONS** 🎭
Created: 2025-12-01

Sources:
- [Besu IBFT 2.0 Documentation](https://besu.hyperledger.org/private-networks/how-to/configure/consensus/ibft)
- [Create a private network using IBFT 2.0](https://besu.hyperledger.org/private-networks/tutorials/ibft)
