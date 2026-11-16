const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('JurisdictionPts1155Bank wallet recipients', function () {
  const JID = 14;
  const POINTS = 375n;
  const CONTROLLER_TOKEN_ID = 1;
  const contextHash = ethers.id('labor-event-timesheet:1');
  let operator;
  let controller;
  let recipient;
  let outsider;
  let voteToken;
  let bank;

  beforeEach(async function () {
    [operator, controller, recipient, outsider] = await ethers.getSigners();
    voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    await voteToken.waitForDeployment();
    await voteToken.mint(controller.address, CONTROLLER_TOKEN_ID, JID);

    bank = await (await ethers.getContractFactory('JurisdictionPts1155Bank'))
      .deploy(operator.address, await voteToken.getAddress(), 'ipfs://pts/');
    await bank.waitForDeployment();
    await bank.configureJurisdiction(JID, operator.address, operator.address);
  });

  it('mints PTS to a wallet with no VoteToken', async function () {
    await expect(bank.mintToWallet(
      recipient.address, JID, POINTS, CONTROLLER_TOKEN_ID, contextHash
    )).to.emit(bank, 'JurisdictionPtsMinted').withArgs(
      JID, recipient.address, POINTS, CONTROLLER_TOKEN_ID, 0, operator.address, contextHash
    );
    expect(await bank.balanceOf(recipient.address, JID)).to.equal(POINTS);
  });

  it('burns PTS from a wallet with no VoteToken', async function () {
    await bank.mintToWallet(recipient.address, JID, POINTS, CONTROLLER_TOKEN_ID, contextHash);
    await expect(bank.burnFromWallet(
      recipient.address, JID, 125, CONTROLLER_TOKEN_ID, ethers.id('labor-payout:1')
    )).to.emit(bank, 'JurisdictionPtsBurned');
    expect(await bank.balanceOf(recipient.address, JID)).to.equal(250);
  });

  it('consumes a wallet settlement context exactly once', async function () {
    await bank.connect(operator).mintToWallet(recipient.address, JID, 50, CONTROLLER_TOKEN_ID, contextHash);
    await expect(
      bank.connect(operator).mintToWallet(recipient.address, JID, 50, CONTROLLER_TOKEN_ID, contextHash)
    ).to.be.revertedWith('JurisdictionPts1155Bank: context already processed');
    expect(await bank.processedWalletContexts(contextHash)).to.equal(true);
  });

  it('still requires an authorized jurisdiction operator', async function () {
    await expect(bank.connect(outsider).mintToWallet(
      recipient.address, JID, POINTS, CONTROLLER_TOKEN_ID, contextHash
    )).to.be.revertedWith('JurisdictionPts1155Bank: sender not jurisdiction operator');
  });

  it('still requires an active controller VoteToken in the jurisdiction', async function () {
    await voteToken.setInactive(CONTROLLER_TOKEN_ID, true);
    await expect(bank.mintToWallet(
      recipient.address, JID, POINTS, CONTROLLER_TOKEN_ID, contextHash
    )).to.be.revertedWith('JurisdictionPts1155Bank: vote token inactive');
  });

  it('retains the voter-bound mint path for backwards compatibility', async function () {
    await voteToken.mint(recipient.address, 2, JID);
    await bank.mintFromControllerToken(
      recipient.address, JID, POINTS, CONTROLLER_TOKEN_ID, 2, contextHash
    );
    expect(await bank.balanceOf(recipient.address, JID)).to.equal(POINTS);
  });
});
