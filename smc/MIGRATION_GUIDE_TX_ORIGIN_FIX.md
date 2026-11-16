# Migration Guide: Fixing `tx.origin` Vulnerability

## 🔄 Migration Steps

### Step 1: Update Contract

Replace the current `VoteTokenMinter.sol` with the fixed version that uses explicit authorization mapping.

**Key Changes:**
- ✅ Removed `tx.origin` check
- ✅ Added `authorizedCallers` mapping
- ✅ Added `Ownable` inheritance
- ✅ Added authorization management functions
- ✅ Added proposal state validation

### Step 2: Deploy Updated Contract

```javascript
// Deploy the fixed contract
const VoteTokenMinter = await ethers.getContractFactory("VoteTokenMinter");
const minter = await VoteTokenMinter.deploy(voteTokenAddress, proposalManagerAddress);
await minter.deployed();

console.log("VoteTokenMinter deployed to:", minter.address);
```

### Step 3: Authorize Backend Services

After deployment, authorize your backend wallet/service:

```javascript
// Authorize backend service wallet
const backendWallet = "0x..."; // Your backend service wallet address
await minter.setAuthorizedCaller(backendWallet, true);

// Verify authorization
const isAuthorized = await minter.isAuthorized(backendWallet);
console.log("Backend authorized:", isAuthorized); // Should be true
```

### Step 4: Update Backend Code

Update your backend to use the authorized wallet:

```javascript
// Before (vulnerable - would work with tx.origin)
const tx = await minter.mintTokensForProposal(
    proposalId,
    jurisdiction,
    tagId,
    voters,
    commitments,
    { from: userWallet } // ❌ This won't work anymore
);

// After (secure - uses authorized backend wallet)
const tx = await minter.mintTokensForProposal(
    proposalId,
    jurisdiction,
    tagId,
    voters,
    commitments,
    { from: backendWallet } // ✅ Authorized wallet
);
```

### Step 5: Test Authorization

```javascript
// Test that unauthorized addresses cannot mint
const unauthorizedWallet = "0x...";
try {
    await minter.connect(unauthorizedWallet).mintTokensForProposal(...);
    console.error("❌ Security test failed - unauthorized mint succeeded");
} catch (error) {
    console.log("✅ Security test passed - unauthorized mint blocked");
}

// Test that authorized addresses can mint
const authorizedWallet = "0x...";
try {
    await minter.connect(authorizedWallet).mintTokensForProposal(...);
    console.log("✅ Authorized mint succeeded");
} catch (error) {
    console.error("❌ Authorized mint failed:", error);
}
```

---

## 🔐 Security Checklist

Before deploying to production:

- [ ] Contract deployed with fixed authorization
- [ ] All backend services have authorized wallets
- [ ] Authorization tested with unauthorized addresses
- [ ] Authorization tested with authorized addresses
- [ ] Owner wallet is secure (multi-sig recommended)
- [ ] Emergency revocation plan documented
- [ ] All team members understand new authorization system

---

## 🚨 Emergency Procedures

### If Backend Wallet is Compromised

```javascript
// Immediately revoke authorization
await minter.setAuthorizedCaller(compromisedWallet, false);

// Verify revocation
const isAuthorized = await minter.isAuthorized(compromisedWallet);
console.log("Compromised wallet authorized:", isAuthorized); // Should be false
```

### If You Need to Authorize Multiple Services

```javascript
// Batch authorize multiple services at once
const serviceWallets = [
    "0x...", // Backend service 1
    "0x...", // Backend service 2
    "0x...", // Discord bot service
];

await minter.setAuthorizedCallersBatch(serviceWallets, true);
```

---

## 📊 Comparison: Before vs After

### Before (Vulnerable)
```solidity
modifier onlyAuthorized() {
    require(
        msg.sender == address(proposalManager) || msg.sender == tx.origin,
        "Not authorized"
    );
    _;
}
```

**Problems:**
- ❌ Any contract can call if user initiates transaction
- ❌ Phishing attacks possible
- ❌ No way to revoke access
- ❌ No audit trail

### After (Secure)
```solidity
mapping(address => bool) public authorizedCallers;

modifier onlyAuthorized() {
    require(
        msg.sender == address(proposalManager) || authorizedCallers[msg.sender],
        "Not authorized to mint"
    );
    _;
}
```

**Benefits:**
- ✅ Only whitelisted addresses can mint
- ✅ Phishing attacks prevented
- ✅ Can revoke access instantly
- ✅ Full audit trail with events

---

## 🧪 Testing Examples

### Test 1: Unauthorized Call Should Fail

```javascript
describe("VoteTokenMinter Security", function() {
    it("Should reject unauthorized minting attempts", async function() {
        const [owner, unauthorized, voter] = await ethers.getSigners();
        
        // Try to mint with unauthorized address
        await expect(
            minter.connect(unauthorized).mintTokensForProposal(
                1,
                ProposalManager.JurisdictionType.ENSEMBLE,
                1,
                [voter.address],
                [ethers.utils.keccak256(ethers.utils.toUtf8Bytes("commitment"))]
            )
        ).to.be.revertedWith("Not authorized to mint");
    });
});
```

### Test 2: Authorized Call Should Succeed

```javascript
it("Should allow authorized backend to mint", async function() {
    const [owner, backend, voter] = await ethers.getSigners();
    
    // Authorize backend
    await minter.connect(owner).setAuthorizedCaller(backend.address, true);
    
    // Backend should be able to mint
    await expect(
        minter.connect(backend).mintTokensForProposal(
            1,
            ProposalManager.JurisdictionType.ENSEMBLE,
            1,
            [voter.address],
            [ethers.utils.keccak256(ethers.utils.toUtf8Bytes("commitment"))]
        )
    ).to.emit(minter, "TokensMintedForProposal");
});
```

### Test 3: Authorization Can Be Revoked

```javascript
it("Should allow owner to revoke authorization", async function() {
    const [owner, backend] = await ethers.getSigners();
    
    // Authorize
    await minter.connect(owner).setAuthorizedCaller(backend.address, true);
    expect(await minter.isAuthorized(backend.address)).to.be.true;
    
    // Revoke
    await minter.connect(owner).setAuthorizedCaller(backend.address, false);
    expect(await minter.isAuthorized(backend.address)).to.be.false;
});
```

---

## 📝 Backend Integration Example

### Node.js/Express Backend

```javascript
const { ethers } = require("ethers");
const minterABI = require("./artifacts/VoteTokenMinter.json").abi;

class VoteTokenMinterService {
    constructor(provider, minterAddress, backendPrivateKey) {
        this.provider = provider;
        this.wallet = new ethers.Wallet(backendPrivateKey, provider);
        this.minter = new ethers.Contract(minterAddress, minterABI, this.wallet);
    }
    
    async mintTokensForProposal(proposalId, jurisdiction, tagId, voters, commitments) {
        // Check authorization first
        const isAuthorized = await this.minter.isAuthorized(this.wallet.address);
        if (!isAuthorized) {
            throw new Error("Backend wallet not authorized to mint");
        }
        
        // Mint tokens
        const tx = await this.minter.mintTokensForProposal(
            proposalId,
            jurisdiction,
            tagId,
            voters,
            commitments
        );
        
        await tx.wait();
        return tx.hash;
    }
}

// Usage
const minterService = new VoteTokenMinterService(
    provider,
    minterAddress,
    process.env.BACKEND_PRIVATE_KEY
);

// Mint tokens when proposal is seconded
await minterService.mintTokensForProposal(
    proposalId,
    1, // ENSEMBLE
    1, // Tag ID
    voterAddresses,
    voterCommitments
);
```

---

## 🔍 Monitoring & Alerts

Set up monitoring for authorization events:

```javascript
// Listen for authorization changes
minter.on("CallerAuthorized", (caller, authorizedBy, timestamp) => {
    console.log(`⚠️  Authorization granted: ${caller} by ${authorizedBy}`);
    // Send alert to security team
});

minter.on("CallerRevoked", (caller, revokedBy, timestamp) => {
    console.log(`✅ Authorization revoked: ${caller} by ${revokedBy}`);
    // Log for audit
});
```

---

## ✅ Summary

**What Changed:**
- Removed dangerous `tx.origin` check
- Added explicit authorization mapping
- Added owner-controlled authorization management
- Added security events for audit trail

**What You Need to Do:**
1. Deploy updated contract
2. Authorize your backend services
3. Update backend code to use authorized wallets
4. Test thoroughly
5. Monitor authorization events

**Security Improvement:**
- 🔴 Before: Vulnerable to phishing and unauthorized minting
- 🟢 After: Secure, auditable, and controllable authorization system

