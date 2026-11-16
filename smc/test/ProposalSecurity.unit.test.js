const { expect } = require('chai');
const { ethers } = require('hardhat');
const { deployCoreContracts } = require('./helpers/fixture');

const YAY = ethers.id('YAY');
const NAY = ethers.id('NAY');

const hashPair = (a, b) => {
  const left = BigInt(a) <= BigInt(b) ? a : b;
  const right = left === a ? b : a;
  return ethers.solidityPackedKeccak256(['bytes32', 'bytes32'], [left, right]);
};

describe('Proposal security hardening', function () {
  let ctx;

  beforeEach(async function () {
    ctx = await deployCoreContracts();
  });

  async function activateDefaultProposal() {
    await ctx.proposalManager.connect(ctx.alice).secondProposal(ctx.defaultProposalId, 7);
  }

  it('restricts setProposalMerkleRoot to owner', async function () {
    await activateDefaultProposal();
    const fakeRoot = ethers.id('root-only-owner');

    await expect(
      ctx.proposalManager.connect(ctx.alice).setProposalMerkleRoot(ctx.defaultProposalId, fakeRoot)
    ).to.be.reverted;

    await expect(
      ctx.proposalManager.connect(ctx.deployer).setProposalMerkleRoot(ctx.defaultProposalId, fakeRoot)
    ).to.emit(ctx.proposalManager, 'MerkleRootSet').withArgs(ctx.defaultProposalId, fakeRoot);
  });

  it('rejects capability vote replay when commitment already has a vote record', async function () {
    await activateDefaultProposal();

    const commitment = ethers.id('commitment-replay-guard');
    const sibling = ethers.id('sibling-replay-guard');
    const merkleRoot = hashPair(commitment, sibling);

    await ctx.proposalManager.connect(ctx.deployer).setProposalMerkleRoot(ctx.defaultProposalId, merkleRoot);

    await ctx.proposalManager.castAnonymousVote(
      ctx.defaultProposalId,
      commitment,
      [sibling],
      ethers.id('nullifier-v1'),
      YAY
    );

    await expect(
      ctx.proposalManager.castAnonymousVoteWithCapability(
        ctx.defaultProposalId,
        1,
        2,
        commitment,
        [sibling],
        ethers.id('nullifier-v2'),
        NAY,
        ethers.id('permit-root'),
        [ethers.id('permit-proof-node')],
        ethers.id('bad-permit-leaf'),
        '0x',
        ctx.alice.address
      )
    ).to.be.revertedWith('Vote already recorded; use changeAnonymousVote');
  });

  it('rejects capability votes when permit leaf payload binding mismatches', async function () {
    await activateDefaultProposal();

    const commitment = ethers.id('commitment-permit-binding');
    const sibling = ethers.id('sibling-permit-binding');
    const merkleRoot = hashPair(commitment, sibling);

    await ctx.proposalManager.connect(ctx.deployer).setProposalMerkleRoot(ctx.defaultProposalId, merkleRoot);

    await expect(
      ctx.proposalManager.castAnonymousVoteWithCapability(
        ctx.defaultProposalId,
        11,
        22,
        commitment,
        [sibling],
        ethers.id('nullifier-capability'),
        YAY,
        ethers.id('permit-root-2'),
        [ethers.id('permit-proof-node-2')],
        ethers.id('wrong-leaf'),
        '0x',
        ctx.alice.address
      )
    ).to.be.revertedWith('Permit leaf payload mismatch');
  });

  it('reverts token casts with jurisdiction mismatch in ProposalBallotBox', async function () {
    const MockVoteTokenForBallot = await ethers.getContractFactory('MockVoteTokenForBallot');
    const mockVoteToken = await MockVoteTokenForBallot.deploy();
    await mockVoteToken.waitForDeployment();

    const nowBlock = await ethers.provider.getBlock('latest');
    const votingWindowEnd = BigInt(nowBlock.timestamp + 3600);

    const ProposalBallotBox = await ethers.getContractFactory('ProposalBallotBox');
    const ballotBox = await ProposalBallotBox.deploy(
      999,
      true,
      ethers.ZeroHash,
      await mockVoteToken.getAddress(),
      ctx.deployer.address,
      votingWindowEnd
    );
    await ballotBox.waitForDeployment();

    await mockVoteToken.mint(ctx.alice.address, 1n, 2n);

    await expect(
      mockVoteToken.connect(ctx.alice).castVoteToBallot(await ballotBox.getAddress(), 1n, YAY)
    ).to.be.revertedWith('Token jurisdiction mismatch');
  });

  it('decrements option tally correctly on token revocation', async function () {
    const MockVoteTokenForBallot = await ethers.getContractFactory('MockVoteTokenForBallot');
    const mockVoteToken = await MockVoteTokenForBallot.deploy();
    await mockVoteToken.waitForDeployment();

    const nowBlock = await ethers.provider.getBlock('latest');
    const votingWindowEnd = BigInt(nowBlock.timestamp + 3600);

    const ProposalBallotBox = await ethers.getContractFactory('ProposalBallotBox');
    const ballotBox = await ProposalBallotBox.deploy(
      1000,
      true,
      ethers.ZeroHash,
      await mockVoteToken.getAddress(),
      ctx.deployer.address,
      votingWindowEnd
    );
    await ballotBox.waitForDeployment();

    await mockVoteToken.mint(ctx.alice.address, 2n, 1n);
    await mockVoteToken.connect(ctx.alice).castVoteToBallot(await ballotBox.getAddress(), 2n, YAY);

    let tally = await ballotBox.getLiveTally();
    expect(tally[0]).to.equal(1n);

    await mockVoteToken.revokeFromBallot(await ballotBox.getAddress(), 2n);

    tally = await ballotBox.getLiveTally();
    expect(tally[0]).to.equal(0n);

    const status = await ballotBox.getStatus();
    expect(status[5]).to.equal(0n);
    expect(status[6]).to.equal(1n);
  });
});
