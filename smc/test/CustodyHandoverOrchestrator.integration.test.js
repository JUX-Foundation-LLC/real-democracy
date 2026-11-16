const { expect } = require('chai');
const { ethers } = require('hardhat');

const b32 = () => ethers.hexlify(ethers.randomBytes(32));
const secrets = () => ({
  cryptoVote: b32(),
  signKey: b32(),
  userBiometric: b32(),
  biometricTypeMask: 0
});

const KIND_VOLUNTARY = 1;
const KIND_RECOVERY = 2;

describe('CustodyHandoverOrchestrator (integration)', function () {
  const JID = 8;
  const PTS = 250n;

  let deployer, custodial, user, other, custodial2;
  let voteToken, bank, registry, orchestrator;
  let voterId, oldTokenId;

  beforeEach(async function () {
    [deployer, custodial, user, other, custodial2] = await ethers.getSigners();

    voteToken = await (await ethers.getContractFactory('VoteToken')).deploy();
    await voteToken.waitForDeployment();

    registry = await (await ethers.getContractFactory('SuccessorRegistry')).deploy(deployer.address);
    await registry.waitForDeployment();

    bank = await (await ethers.getContractFactory('JurisdictionPts1155Bank'))
      .deploy(deployer.address, await voteToken.getAddress(), 'ipfs://pts/');
    await bank.waitForDeployment();

    orchestrator = await (await ethers.getContractFactory('CustodyHandoverOrchestrator')).deploy(
      deployer.address,
      await voteToken.getAddress(),
      await bank.getAddress(),
      await registry.getAddress()
    );
    await orchestrator.waitForDeployment();

    // Wire the roles the orchestrator needs.
    await voteToken.grantRole(await voteToken.CUSTODIAN_ROLE(), await orchestrator.getAddress());
    await registry.grantRole(await registry.RECORDER_ROLE(), await orchestrator.getAddress());
    // Jurisdiction operator: governor = deployer, bootstrap operator = orchestrator.
    await bank.configureJurisdiction(JID, deployer.address, await orchestrator.getAddress());

    // Issue the original (custodial) token + fund it with PTS.
    voterId = b32();
    await voteToken.issueToken(custodial.address, voterId, JID, secrets(), b32(), b32());
    oldTokenId = await voteToken.activeTokenOf(voterId, JID);

    await bank.mintFromControllerToken(custodial.address, JID, PTS, oldTokenId, oldTokenId, b32());
    expect(await bank.balanceOf(custodial.address, JID)).to.equal(PTS);
  });

  it('moves token custody and PTS to the user wallet atomically, recording the link', async function () {
    const tx = await orchestrator.handover(oldTokenId, user.address, secrets(), b32(), KIND_VOLUNTARY, 'self-custody');
    await tx.wait();

    const newTokenId = await voteToken.activeTokenOf(voterId, JID);
    expect(newTokenId).to.not.equal(oldTokenId);

    // Old token: disabled (never burned), still readable, no longer active.
    expect(await voteToken.isActive(oldTokenId)).to.equal(false);
    const oldInfo = await voteToken.tokenInfo(oldTokenId);
    expect(oldInfo.disabled).to.equal(true);
    expect(oldInfo.voterId).to.equal(voterId); // history preserved
    expect(await voteToken.ownerOf(oldTokenId)).to.equal(custodial.address);

    // New token: active, owned by the user, same voter identity.
    expect(await voteToken.isActive(newTokenId)).to.equal(true);
    expect(await voteToken.ownerOf(newTokenId)).to.equal(user.address);
    expect((await voteToken.tokenInfo(newTokenId)).voterId).to.equal(voterId);

    // PTS fully swept: nothing left behind, exact balance on the new wallet.
    expect(await bank.balanceOf(custodial.address, JID)).to.equal(0n);
    expect(await bank.balanceOf(user.address, JID)).to.equal(PTS);

    // Unbroken on-chain link recorded.
    expect(await registry.successorOf(oldTokenId)).to.equal(newTokenId);
    expect(await registry.predecessorOf(newTokenId)).to.equal(oldTokenId);
    expect((await registry.recordOf(oldTokenId)).kind).to.equal(KIND_VOLUNTARY);
  });

  it('emits CustodyHandedOver with the moved balance', async function () {
    await expect(orchestrator.handover(oldTokenId, user.address, secrets(), b32(), KIND_RECOVERY, 'lost key'))
      .to.emit(orchestrator, 'CustodyHandedOver');
    const newTokenId = await voteToken.activeTokenOf(voterId, JID);
    expect((await registry.recordOf(oldTokenId)).kind).to.equal(KIND_RECOVERY);
    expect(await bank.balanceOf(user.address, JID)).to.equal(PTS);
    expect(newTokenId).to.not.equal(oldTokenId);
  });

  it('handles a zero-PTS handover (no burn/mint, still hands over + records)', async function () {
    // INVARIANT: PTS is keyed by (wallet, jurisdiction), not by token, so a
    // clean per-user sweep requires one custodial wallet per user. Use a
    // distinct unfunded wallet here (custodial2) to model that.
    const vId2 = b32();
    await voteToken.issueToken(custodial2.address, vId2, JID, secrets(), b32(), b32());
    const t2 = await voteToken.activeTokenOf(vId2, JID);
    expect(await bank.balanceOf(custodial2.address, JID)).to.equal(0n);

    await orchestrator.handover(t2, other.address, secrets(), b32(), KIND_VOLUNTARY, 'no pts');
    const new2 = await voteToken.activeTokenOf(vId2, JID);
    expect(await voteToken.ownerOf(new2)).to.equal(other.address);
    expect(await bank.balanceOf(other.address, JID)).to.equal(0n);
    expect(await registry.successorOf(t2)).to.equal(new2);
  });

  it('rejects handover of an inactive token', async function () {
    // Disable the token directly first.
    await voteToken.adminDisable(oldTokenId);
    await expect(
      orchestrator.handover(oldTokenId, user.address, secrets(), b32(), KIND_VOLUNTARY, 'x')
    ).to.be.revertedWithCustomError(orchestrator, 'InactiveSourceToken');
  });

  it('rejects callers without HANDOVER_OPERATOR_ROLE', async function () {
    await expect(
      orchestrator.connect(other).handover(oldTokenId, user.address, secrets(), b32(), KIND_VOLUNTARY, 'x')
    ).to.be.reverted;
  });

  it('rejects a zero-address new owner', async function () {
    await expect(
      orchestrator.handover(oldTokenId, ethers.ZeroAddress, secrets(), b32(), KIND_VOLUNTARY, 'x')
    ).to.be.revertedWithCustomError(orchestrator, 'InvalidNewOwner');
  });
});
