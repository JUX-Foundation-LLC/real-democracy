const { expect } = require('chai');
const { ethers } = require('hardhat');
const { deployCoreContracts, defaultSecrets, makeVoterId } = require('./helpers/fixture');

describe('VoteTokenMinter unit tests', function () {
  let ctx;

  beforeEach(async function () {
    ctx = await deployCoreContracts();
  });

  const buildIssueRequest = (overrides = {}) => ({
    wallet: ctx.alice.address,
    voterId: makeVoterId('minter-voter'),
    jurisdictionId: 10n,
    secrets: defaultSecrets(),
    policyDigest: ethers.id('policy/batch'),
    stealthCommitment: ethers.id('stealth/batch'),
    ...overrides,
  });

  it('requires ISSUER_ROLE to issue batches', async function () {
    const request = buildIssueRequest();

    await expect(
      ctx.voteTokenMinter.connect(ctx.alice).issueBatch([request])
    ).to.be.revertedWith(/AccessControl: account/);
  });

  it('issues proposal batches and records token ids', async function () {
    const request = buildIssueRequest();
    const proposalId = ctx.defaultProposalId;

    const preview = await ctx.voteTokenMinter
      .connect(ctx.deployer)
      .issueProposalBatch.staticCall(proposalId, [request]);

    await expect(
      ctx.voteTokenMinter.connect(ctx.deployer).issueProposalBatch(proposalId, [request])
    )
      .to.emit(ctx.voteTokenMinter, 'ProposalTokenIssued')
      .withArgs(
        proposalId,
        preview[0],
        request.wallet,
        request.voterId,
        request.jurisdictionId,
        request.policyDigest,
        request.stealthCommitment
      );

    const recorded = await ctx.voteTokenMinter.tokensForProposal(proposalId);
    expect(recorded.map((id) => id)).to.deep.equal(preview.map((id) => id));
    expect(await ctx.voteToken.ownerOf(preview[0])).to.equal(request.wallet);
  });

  it('hands custody over via the VoteToken when requested', async function () {
    const voterId = makeVoterId('custody-transfer');
    const jurisdictionId = 11n;
    const proposalId = ctx.defaultProposalId;
    const request = buildIssueRequest({
      voterId,
      jurisdictionId,
      wallet: ctx.alice.address,
      policyDigest: ethers.id('policy/custody'),
      stealthCommitment: ethers.id('stealth/custody'),
    });

    await ctx.voteTokenMinter.connect(ctx.deployer).issueProposalBatch(proposalId, [request]);
    const [tokenId] = await ctx.voteTokenMinter.tokensForProposal(proposalId);

    await expect(
      ctx.voteTokenMinter
        .connect(ctx.deployer)
        .handoverCustody(tokenId, ctx.bob.address, defaultSecrets(), ethers.id('stealth/new-holder'))
    ).to.emit(ctx.voteTokenMinter, 'CustodyHandedOver');

    const activeToken = await ctx.voteToken.activeTokenOf(voterId, jurisdictionId);
    expect(await ctx.voteToken.ownerOf(activeToken)).to.equal(ctx.bob.address);
  });
});
