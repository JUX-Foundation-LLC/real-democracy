const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('BooleanRuleBallotBox', function () {
  const J = 9;
  const T_A = 1;
  const T_B = 2;
  const T_C = 3;
  const ruleKey = ethers.id('test_rule');

  let deployer, alice, bob, carol, outsider, voteToken, box;

  beforeEach(async function () {
    [deployer, alice, bob, carol, outsider] = await ethers.getSigners();

    const Mock = await ethers.getContractFactory('MockVoteTokenForExecutor');
    voteToken = await Mock.deploy();
    await voteToken.waitForDeployment();
    await voteToken.mint(alice.address, T_A, J);
    await voteToken.mint(bob.address, T_B, J);
    await voteToken.mint(carol.address, T_C, J);

    const Box = await ethers.getContractFactory('BooleanRuleBallotBox');
    box = await Box.deploy(await voteToken.getAddress(), J, deployer.address, ethers.ZeroAddress, 6000, ethers.ZeroAddress);
    await box.waitForDeployment();
    await box.registerRule(ruleKey, ethers.ZeroHash, '0x');
  });

  it('returns (0,0,false) with no votes', async function () {
    const [v, total, q] = await box.currentResult(ruleKey);
    expect(total).to.equal(0n);
    expect(v).to.equal(0n);
    expect(q).to.equal(false);
  });

  it('tallies support/oppose as bps + meets quorum', async function () {
    await box.connect(alice).castVote(ruleKey, T_A, [1]); // support
    await box.connect(bob).castVote(ruleKey, T_B, [1]);   // support
    await box.connect(carol).castVote(ruleKey, T_C, [0]); // oppose
    const [v, total, q] = await box.currentResult(ruleKey);
    expect(total).to.equal(3n);
    expect(v).to.equal(6666n); // 2 * 10000 / 3
    expect(q).to.equal(true);  // 6666 >= 6000
  });

  it('re-vote decrements EXACTLY — no double count', async function () {
    await box.connect(alice).castVote(ruleKey, T_A, [1]); // support
    await box.connect(bob).castVote(ruleKey, T_B, [1]);   // support
    await box.connect(alice).castVote(ruleKey, T_A, [0]); // alice flips to oppose

    const [v, total] = await box.currentResult(ruleKey);
    expect(total).to.equal(2n);   // still 2 distinct voters
    expect(v).to.equal(5000n);    // 1 support / 2 = 5000
    const t = await box.tallies(ruleKey);
    expect(t.support).to.equal(1n);
    expect(t.oppose).to.equal(1n);

    // idempotent re-vote of the same value changes nothing
    await box.connect(alice).castVote(ruleKey, T_A, [0]);
    const t2 = await box.tallies(ruleKey);
    expect(t2.support).to.equal(1n);
    expect(t2.oppose).to.equal(1n);
  });

  it('rejects ineligible voters (owner / active / jurisdiction)', async function () {
    await expect(box.connect(outsider).castVote(ruleKey, T_A, [1]))
      .to.be.revertedWith('RuleBox: not token owner');
    await voteToken.setInactive(T_A, true);
    await expect(box.connect(alice).castVote(ruleKey, T_A, [1]))
      .to.be.revertedWith('RuleBox: inactive token');
  });

  it('rejects bad ballots + unknown rule', async function () {
    await expect(box.connect(alice).castVote(ruleKey, T_A, [2]))
      .to.be.revertedWith('BooleanRuleBox: ballot must be [0] or [1]');
    await expect(box.connect(alice).castVote(ethers.id('nope'), T_A, [1]))
      .to.be.revertedWith('RuleBox: unknown rule');
  });

  it('only governor registers rules', async function () {
    await expect(box.connect(alice).registerRule(ethers.id('x'), ethers.ZeroHash, '0x'))
      .to.be.revertedWith('RuleBox: only governor');
  });

  it('exposes structureId + ERC-165 (IRuleBallotBox)', async function () {
    expect(await box.structureId()).to.equal(ethers.id('boolean'));
    expect(await box.supportsInterface('0x01ffc9a7')).to.equal(true);  // ERC165
    expect(await box.supportsInterface('0xffffffff')).to.equal(false);

    // IRuleBallotBox interfaceId = XOR of its external function selectors
    const iface = new ethers.Interface([
      'function registerRule(bytes32,bytes32,bytes)',
      'function castVote(bytes32,uint256,uint16[])',
      'function currentResult(bytes32) view returns (int256,uint256,bool)',
      'function structureId() view returns (bytes32)',
      'function jurisdictionId() view returns (uint256)'
    ]);
    let id = 0n;
    iface.forEachFunction((f) => { id ^= BigInt(f.selector); });
    const interfaceId = '0x' + id.toString(16).padStart(8, '0');
    expect(await box.supportsInterface(interfaceId)).to.equal(true);
  });
});
