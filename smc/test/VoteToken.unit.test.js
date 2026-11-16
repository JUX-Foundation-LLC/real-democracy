const { expect } = require('chai');
const { ethers } = require('hardhat');
const { deployCoreContracts, defaultSecrets, makeVoterId } = require('./helpers/fixture');

describe('VoteToken (V3) unit tests', function () {
  let ctx;

  beforeEach(async function () {
    ctx = await deployCoreContracts();
  });

  const issueToken = async ({
    owner,
    voterLabel,
    jurisdictionId = 1n,
    policyLabel = 'policy/base',
    stealthLabel = 'stealth/base',
  }) => {
    const voterId = makeVoterId(voterLabel);
    const policyDigest = ethers.id(policyLabel);
    const stealthCommitment = ethers.id(stealthLabel);

    await ctx.voteToken.connect(ctx.custodian).issueToken(
      owner,
      voterId,
      jurisdictionId,
      defaultSecrets(),
      policyDigest,
      stealthCommitment
    );

    const tokenId = await ctx.voteToken.activeTokenOf(voterId, jurisdictionId);
    return { tokenId, voterId, jurisdictionId, policyDigest, stealthCommitment };
  };

  it('allows a custodian to issue a token and tracks it as active', async function () {
    const voterId = makeVoterId('alice-j1');
    const jurisdictionId = 1n;
    const policyDigest = ethers.id('policy/alice');
    const stealthCommitment = ethers.id('stealth/alice');

    await expect(
      ctx.voteToken.connect(ctx.custodian).issueToken(
        ctx.alice.address,
        voterId,
        jurisdictionId,
        defaultSecrets(),
        policyDigest,
        stealthCommitment
      )
    )
      .to.emit(ctx.voteToken, 'TokenIssued')
      .withArgs(
        1n,
        voterId,
        jurisdictionId,
        ctx.alice.address,
        ctx.custodian.address,
        policyDigest,
        stealthCommitment
      );

    const activeToken = await ctx.voteToken.activeTokenOf(voterId, jurisdictionId);
    const info = await ctx.voteToken.tokenInfo(activeToken);
    expect(activeToken).to.equal(1n);
    expect(info.disabled).to.equal(false);
    expect(await ctx.voteToken.ownerOf(activeToken)).to.equal(ctx.alice.address);
  });

  it('prevents approvals to keep tokens soulbound', async function () {
    await expect(
      ctx.voteToken.connect(ctx.deployer).approve(ctx.deployer.address, 1n)
    ).to.be.revertedWithCustomError(ctx.voteToken, 'SoulboundTransferBlocked');

    await expect(
      ctx.voteToken.connect(ctx.deployer).setApprovalForAll(ctx.deployer.address, true)
    ).to.be.revertedWithCustomError(ctx.voteToken, 'SoulboundTransferBlocked');
  });

  it('allows custodians to rotate secrets and bumps revocation nonce', async function () {
    const { tokenId } = await issueToken({ owner: ctx.alice.address, voterLabel: 'alice-j2', jurisdictionId: 2n });
    const before = await ctx.voteToken.revocationNonceOf(tokenId);
    const updatedSecrets = defaultSecrets({ signKey: ethers.id('new-sign-key') });
    const policyDigest = ethers.id('policy/rotated');

    await expect(
      ctx.voteToken.connect(ctx.custodian).updateSecrets(tokenId, updatedSecrets, policyDigest)
    )
      .to.emit(ctx.voteToken, 'TokenSecretsUpdated')
      .withArgs(tokenId, ctx.custodian.address, updatedSecrets.signKey, policyDigest, before + 1n);

    const after = await ctx.voteToken.revocationNonceOf(tokenId);
    expect(after).to.equal(before + 1n);
  });

  it('supports the legacy mint bridge for backwards compatibility', async function () {
    const tx = await ctx.voteToken.connect(ctx.custodian).mint(ctx.bob.address, true, ethers.id('show/alpha'));
    const receipt = await tx.wait();
    const issuedLog = receipt.logs.find((log) => log.fragment?.name === 'TokenIssued');
    expect(issuedLog).to.exist;
    const mintedTokenId = issuedLog.args.tokenId;
    expect(await ctx.voteToken.ownerOf(mintedTokenId)).to.equal(ctx.bob.address);
  });

  it('disables the previous token when custody is handed over', async function () {
    const { tokenId: oldTokenId, voterId, jurisdictionId } = await issueToken({
      owner: ctx.alice.address,
      voterLabel: 'alice-handover',
      jurisdictionId: 3n,
    });

    await expect(
      ctx.voteToken
        .connect(ctx.custodian)
        .handoverCustody(oldTokenId, ctx.bob.address, defaultSecrets(), ethers.id('stealth/new-owner'))
    ).to.emit(ctx.voteToken, 'TokenCustodyHandover');

    const oldInfo = await ctx.voteToken.tokenInfo(oldTokenId);
    expect(oldInfo.disabled).to.equal(true);

    const newTokenId = await ctx.voteToken.activeTokenOf(voterId, jurisdictionId);
    expect(newTokenId).to.not.equal(0n);
    const newInfo = await ctx.voteToken.tokenInfo(newTokenId);
    expect(newInfo.disabled).to.equal(false);
    expect(await ctx.voteToken.ownerOf(newTokenId)).to.equal(ctx.bob.address);
  });

  it('reveals that reentrant receivers can self-disable tokens during mint', async function () {
    const MockReceiver = await ethers.getContractFactory('MockReceiver', { signer: ctx.deployer });
    const receiver = await MockReceiver.deploy(await ctx.voteToken.getAddress());
    await receiver.waitForDeployment();
    await (await receiver.setReenter(true)).wait();

    const voterId = makeVoterId('reentrant-voter');
    const jurisdictionId = 4n;

    await ctx.voteToken
      .connect(ctx.custodian)
      .issueToken(await receiver.getAddress(), voterId, jurisdictionId, defaultSecrets(), ethers.id('policy/reenter'), ethers.id('stealth/reenter'));

    const tokenId = await ctx.voteToken.activeTokenOf(voterId, jurisdictionId);
    expect(tokenId).to.not.equal(0n);
    const info = await ctx.voteToken.tokenInfo(tokenId);
    // Current implementation overwrites the disabled flag after reentrant callbacks.
    expect(info.disabled).to.equal(false);
    expect(info.revocationNonce).to.equal(0n);
  });

  describe('activeTokenCount — the G1 turnout denominator', function () {
    it('increments per jurisdiction on issue, isolated across jurisdictions', async function () {
      expect(await ctx.voteToken.activeTokenCount(1n)).to.equal(0n);
      await issueToken({ owner: ctx.alice.address, voterLabel: 'a-j1', jurisdictionId: 1n });
      await issueToken({ owner: ctx.bob.address, voterLabel: 'b-j1', jurisdictionId: 1n });
      await issueToken({ owner: ctx.alice.address, voterLabel: 'a-j2', jurisdictionId: 2n });
      expect(await ctx.voteToken.activeTokenCount(1n)).to.equal(2n);
      expect(await ctx.voteToken.activeTokenCount(2n)).to.equal(1n);
    });

    it('decrements on disable', async function () {
      const { tokenId } = await issueToken({ owner: ctx.alice.address, voterLabel: 'a-dis', jurisdictionId: 1n });
      await issueToken({ owner: ctx.bob.address, voterLabel: 'b-dis', jurisdictionId: 1n });
      expect(await ctx.voteToken.activeTokenCount(1n)).to.equal(2n);
      await ctx.voteToken.connect(ctx.custodian).custodianDisable(tokenId);
      expect(await ctx.voteToken.activeTokenCount(1n)).to.equal(1n);
    });

    it('is unchanged by a custody handover (disable-old + issue-new = net 0)', async function () {
      const { tokenId } = await issueToken({ owner: ctx.alice.address, voterLabel: 'a-ho', jurisdictionId: 3n });
      expect(await ctx.voteToken.activeTokenCount(3n)).to.equal(1n);
      await ctx.voteToken.connect(ctx.custodian)
        .handoverCustody(tokenId, ctx.bob.address, defaultSecrets(), ethers.id('stealth/ho-new'));
      expect(await ctx.voteToken.activeTokenCount(3n)).to.equal(1n);
    });
  });
});
