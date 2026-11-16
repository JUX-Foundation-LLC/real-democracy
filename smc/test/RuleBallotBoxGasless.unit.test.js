const { expect } = require('chai');
const { ethers } = require('hardhat');

/**
 * Gasless voting (EIP-2771): a voter signs a `castVote` off-chain; a SEPARATE shared
 * gas-payer (the relayer) submits it through the trusted forwarder and pays the gas. The
 * box must attribute the vote to the real VOTER (`_msgSender()`), not the relayer — and a
 * relayer that is NOT the token owner must not be able to vote on its own behalf.
 *
 * This is the contract-side proof of the model Coi asked for: self-custody voters never
 * pay gas, a shared wallet pays for every verified action, attribution stays correct.
 */
describe('RuleBallotBox — gasless via EIP-2771 forwarder', function () {
  const J = 7;
  const ruleKey = ethers.id('use_real_democracy');
  let forwarder, voteToken, box;
  let relayer, voter, voter2;

  // sign a MinimalForwarder ForwardRequest as `from`
  async function signRequest(from, to, data) {
    const nonce = await forwarder.getNonce(from.address);
    const req = { from: from.address, to, value: 0, gas: 1_000_000, nonce, data };
    const net = await ethers.provider.getNetwork();
    const domain = {
      name: 'MinimalForwarder',
      version: '0.0.1',
      chainId: net.chainId,
      verifyingContract: await forwarder.getAddress(),
    };
    const types = {
      ForwardRequest: [
        { name: 'from', type: 'address' },
        { name: 'to', type: 'address' },
        { name: 'value', type: 'uint256' },
        { name: 'gas', type: 'uint256' },
        { name: 'nonce', type: 'uint256' },
        { name: 'data', type: 'bytes' },
      ],
    };
    const signature = await from.signTypedData(domain, types, req);
    return { req, signature };
  }

  beforeEach(async function () {
    [relayer, voter, voter2] = await ethers.getSigners();

    forwarder = await (await ethers.getContractFactory('SharedGasPayerForwarder')).deploy();
    await forwarder.waitForDeployment();

    voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    await voteToken.waitForDeployment();
    await voteToken.mint(voter.address, 1, J);
    await voteToken.mint(voter2.address, 2, J);

    box = await (await ethers.getContractFactory('BooleanRuleBallotBox')).deploy(
      await voteToken.getAddress(),
      J,
      relayer.address, // governor (just needs to register the rule here)
      ethers.ZeroAddress,
      6000,
      await forwarder.getAddress(), // trusted forwarder = the shared gas-payer's forwarder
    );
    await box.waitForDeployment();
    await box.registerRule(ruleKey, ethers.ZeroHash, '0x');
  });

  it('relayer submits + pays gas; the vote is attributed to the signing voter', async function () {
    const data = box.interface.encodeFunctionData('castVote', [ruleKey, 1, [1]]); // support
    const { req, signature } = await signRequest(voter, await box.getAddress(), data);

    expect(await forwarder.verify(req, signature)).to.equal(true);

    const voterBalBefore = await ethers.provider.getBalance(voter.address);
    // relayer (NOT the voter) submits and pays
    await forwarder.connect(relayer).execute(req, signature);
    const voterBalAfter = await ethers.provider.getBalance(voter.address);

    // voter spent ZERO gas — fully gasless
    expect(voterBalAfter).to.equal(voterBalBefore);

    // vote counted, attributed to the voter's token
    const [value, total] = await box.currentResult(ruleKey);
    expect(total).to.equal(1n);
    expect(value).to.equal(10000n); // 100% support
    expect(await box.getLastBallot(ruleKey, 1)).to.deep.equal([1n]);
  });

  it('a relayed vote still enforces token ownership (relayer cannot vote token it does not own)', async function () {
    // voter signs but for token 2 (owned by voter2) → ownerOf(_msgSender()) check fails
    const data = box.interface.encodeFunctionData('castVote', [ruleKey, 2, [1]]);
    const { req, signature } = await signRequest(voter, await box.getAddress(), data);

    // MinimalForwarder swallows the inner revert (returns success=false); the state must be untouched
    await forwarder.connect(relayer).execute(req, signature);
    const [, total] = await box.currentResult(ruleKey);
    expect(total).to.equal(0n); // no vote recorded
  });

  it('two voters relayed by one shared payer are attributed distinctly', async function () {
    const d1 = box.interface.encodeFunctionData('castVote', [ruleKey, 1, [1]]); // support
    const d2 = box.interface.encodeFunctionData('castVote', [ruleKey, 2, [0]]); // oppose
    const s1 = await signRequest(voter, await box.getAddress(), d1);
    const s2 = await signRequest(voter2, await box.getAddress(), d2);

    await forwarder.connect(relayer).execute(s1.req, s1.signature);
    await forwarder.connect(relayer).execute(s2.req, s2.signature);

    const [value, total] = await box.currentResult(ruleKey);
    expect(total).to.equal(2n);
    expect(value).to.equal(5000n); // 1 support / 1 oppose = 50%
  });
});
