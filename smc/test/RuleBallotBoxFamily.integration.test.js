const { expect } = require('chai');
const { ethers } = require('hardhat');

/**
 * Integration: a single jurisdiction runs THREE rules of different structures
 * (boolean + median + plurality), each on its own structure-box, all bound in one
 * registry, and a consumer reads every result uniformly via registry.resultFor().
 * Proves the B.2 family deploys + composes as a whole system.
 */
describe('Rule ballotbox family — integration', function () {
  const J = 12;
  const N = 5;
  let deployer, voters, voteToken, registry, boolBox, medBox, plurBox;

  const ruleDeclaration = ethers.id('use_real_democracy'); // boolean
  const ruleQuorum = ethers.id('quorum_threshold');        // median
  const ruleTallyMode = ethers.id('tally_mode');           // plurality (0=hide,1=reveal,2=mixed)

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    deployer = signers[0];
    voters = signers.slice(1, 1 + N);

    const Mock = await ethers.getContractFactory('MockVoteTokenForExecutor');
    voteToken = await Mock.deploy();
    await voteToken.waitForDeployment();
    for (let i = 0; i < N; i++) await voteToken.mint(voters[i].address, i + 1, J);

    const vt = await voteToken.getAddress();
    boolBox = await (await ethers.getContractFactory('BooleanRuleBallotBox')).deploy(vt, J, deployer.address, ethers.ZeroAddress, 6000, ethers.ZeroAddress);
    medBox = await (await ethers.getContractFactory('MedianRuleBallotBox')).deploy(vt, J, deployer.address, ethers.ZeroAddress, 5000, ethers.ZeroAddress);
    plurBox = await (await ethers.getContractFactory('PluralityRuleBallotBox')).deploy(vt, J, deployer.address, ethers.ZeroAddress, 5000, ethers.ZeroAddress);
    await Promise.all([boolBox.waitForDeployment(), medBox.waitForDeployment(), plurBox.waitForDeployment()]);

    registry = await (await ethers.getContractFactory('JurisdictionRuleRegistry')).deploy(deployer.address);
    await registry.waitForDeployment();

    // register each rule on its structure box
    await boolBox.registerRule(ruleDeclaration, ethers.ZeroHash, '0x');
    await medBox.registerRule(ruleQuorum, ethers.ZeroHash, ethers.AbiCoder.defaultAbiCoder().encode(['uint16'], [100]));
    await plurBox.registerRule(ruleTallyMode, ethers.ZeroHash, ethers.AbiCoder.defaultAbiCoder().encode(['uint16'], [3]));

    // bind all three into the one registry
    await registry.bindRuleBox(J, ruleDeclaration, await boolBox.getAddress());
    await registry.bindRuleBox(J, ruleQuorum, await medBox.getAddress());
    await registry.bindRuleBox(J, ruleTallyMode, await plurBox.getAddress());
  });

  it('runs 3 structures in one jurisdiction, read uniformly through the registry', async function () {
    // Declaration (boolean): 4 support, 1 oppose → 8000 bps
    for (let i = 0; i < 5; i++) await boolBox.connect(voters[i]).castVote(ruleDeclaration, i + 1, [i < 4 ? 1 : 0]);
    // Quorum (median): [30,40,50,45,35] → median 40
    for (const [i, val] of [30, 40, 50, 45, 35].entries()) await medBox.connect(voters[i]).castVote(ruleQuorum, i + 1, [val]);
    // Tally mode (plurality): choice 1 wins (3 votes vs 2 vs 0)
    for (const [i, c] of [1, 1, 1, 2, 2].entries()) await plurBox.connect(voters[i]).castVote(ruleTallyMode, i + 1, [c]);

    const decl = await registry.resultFor(J, ruleDeclaration);
    const quorum = await registry.resultFor(J, ruleQuorum);
    const tally = await registry.resultFor(J, ruleTallyMode);

    expect(decl.value).to.equal(8000n);   // 80% support
    expect(decl.quorumMet).to.equal(true); // >= 6000
    expect(quorum.value).to.equal(40n);    // median
    expect(tally.value).to.equal(1n);      // winning choice
    expect(decl.totalVotes).to.equal(5n);
    expect(quorum.totalVotes).to.equal(5n);
    expect(tally.totalVotes).to.equal(5n);
  });

  it('a consumer contract can read a live result through the registry', async function () {
    for (const [i, val] of [30, 40, 50, 45, 35].entries()) await medBox.connect(voters[i]).castVote(ruleQuorum, i + 1, [val]);
    // simulate a consumer: call resultFor and act on it
    const [value, total, quorumMet] = await registry.resultFor(J, ruleQuorum);
    expect(value).to.equal(40n);
    expect(total).to.equal(5n);
    expect(quorumMet).to.equal(true);
  });
});
