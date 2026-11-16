const { expect } = require('chai');
const { ethers } = require('hardhat');

// §8.2 (FOLLOW): the registry is generalized — open delegate votes are keyed by the unified
// externalNullifier (any ballot family/domain), and the choice is a uint256 matching the
// ballot's voteChoice domain (boolean 1/0, median value, plurality choice). Withdraw replaces
// the old CHOICE_UNCAST.
describe('PublicDelegateVoteRegistry (generalized — every ballot, rich choice)', function () {
  let delegate, stranger, voteToken, registry;
  const TOKEN_DELEGATE = 5;
  const JURISDICTION_ID = 10;
  // externalNullifiers = the unified ballot keys (backend = keccak(str) mod prime; here distinct uints)
  const EXT_PROPOSAL = 111n; // e.g. keccak("proposal:1")
  const EXT_RULE = 222n;     // e.g. keccak("rule:10:quorum_threshold")
  const SUPPORT = 1n, OPPOSE = 0n, MEDIAN_VALUE = 50n;

  beforeEach(async function () {
    [, delegate, stranger] = await ethers.getSigners();
    voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    await voteToken.waitForDeployment();
    await voteToken.mint(delegate.address, TOKEN_DELEGATE, JURISDICTION_ID);
    registry = await (await ethers.getContractFactory('PublicDelegateVoteRegistry')).deploy(await voteToken.getAddress());
    await registry.waitForDeployment();
  });

  it('records an open vote keyed by externalNullifier (boolean support)', async function () {
    await expect(registry.connect(delegate).castPublicDelegateVote(EXT_PROPOSAL, TOKEN_DELEGATE, SUPPORT))
      .to.emit(registry, 'PublicDelegateVoteCast')
      .withArgs(EXT_PROPOSAL, TOKEN_DELEGATE, delegate.address, JURISDICTION_ID, SUPPORT, 1, true);
    const [choice, castAt, revision, cast] = await registry.getPublicVote(EXT_PROPOSAL, TOKEN_DELEGATE);
    expect(choice).to.equal(SUPPORT);
    expect(castAt).to.be.greaterThan(0n);
    expect(revision).to.equal(1);
    expect(cast).to.equal(true);
  });

  it('carries a rich uint256 choice (median value) on a rule-scoped ballot', async function () {
    await registry.connect(delegate).castPublicDelegateVote(EXT_RULE, TOKEN_DELEGATE, MEDIAN_VALUE);
    expect((await registry.getPublicVote(EXT_RULE, TOKEN_DELEGATE))[0]).to.equal(MEDIAN_VALUE);
  });

  it('keeps positions on different ballots independent (per externalNullifier)', async function () {
    await registry.connect(delegate).castPublicDelegateVote(EXT_PROPOSAL, TOKEN_DELEGATE, SUPPORT);
    await registry.connect(delegate).castPublicDelegateVote(EXT_RULE, TOKEN_DELEGATE, MEDIAN_VALUE);
    expect((await registry.getPublicVote(EXT_PROPOSAL, TOKEN_DELEGATE))[0]).to.equal(SUPPORT);
    expect((await registry.getPublicVote(EXT_RULE, TOKEN_DELEGATE))[0]).to.equal(MEDIAN_VALUE);
  });

  it('revises openly with an incrementing revision', async function () {
    await registry.connect(delegate).castPublicDelegateVote(EXT_PROPOSAL, TOKEN_DELEGATE, SUPPORT);
    await registry.connect(delegate).castPublicDelegateVote(EXT_PROPOSAL, TOKEN_DELEGATE, OPPOSE);
    const [choice, , revision] = await registry.getPublicVote(EXT_PROPOSAL, TOKEN_DELEGATE);
    expect(choice).to.equal(OPPOSE);
    expect(revision).to.equal(2);
  });

  it('withdraw sets cast=false (old UNCAST) + revisions, and a second withdraw reverts', async function () {
    await registry.connect(delegate).castPublicDelegateVote(EXT_PROPOSAL, TOKEN_DELEGATE, SUPPORT);
    await expect(registry.connect(delegate).withdrawPublicDelegateVote(EXT_PROPOSAL, TOKEN_DELEGATE))
      .to.emit(registry, 'PublicDelegateVoteCast')
      .withArgs(EXT_PROPOSAL, TOKEN_DELEGATE, delegate.address, JURISDICTION_ID, SUPPORT, 2, false);
    const [, , revision, cast] = await registry.getPublicVote(EXT_PROPOSAL, TOKEN_DELEGATE);
    expect(cast).to.equal(false);
    expect(revision).to.equal(2);
    await expect(registry.connect(delegate).withdrawPublicDelegateVote(EXT_PROPOSAL, TOKEN_DELEGATE))
      .to.be.revertedWith('Registry: nothing to withdraw');
  });

  it('rejects non-owners and inactive tokens', async function () {
    await expect(registry.connect(stranger).castPublicDelegateVote(EXT_PROPOSAL, TOKEN_DELEGATE, SUPPORT))
      .to.be.revertedWith('Registry: not token owner');
    await voteToken.setInactive(TOKEN_DELEGATE, true);
    await expect(registry.connect(delegate).castPublicDelegateVote(EXT_PROPOSAL, TOKEN_DELEGATE, SUPPORT))
      .to.be.revertedWith('Registry: vote token inactive');
  });
});
