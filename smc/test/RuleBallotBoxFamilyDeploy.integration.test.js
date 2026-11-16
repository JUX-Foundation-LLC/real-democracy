const { expect } = require('chai');
const { ethers } = require('hardhat');

/**
 * Deploy-topology proof for the B.2 family — the exact shape the re-genesis deploy script
 * stands up, exercised on a Hardhat node so we find the breakpoints BEFORE the prod cut:
 *
 *   1 trusted forwarder (the shared gas-payer)         — gasless for every box
 *   1 global JurisdictionRuleRegistry                     — the consumer read surface
 *   per jurisdiction: the structure boxes it needs     — boolean / median / plurality here
 *   bootstrap: deployer registers rules + binds        — REGISTRAR_ROLE
 *   handoff:  governorship → the executor              — config becomes vote-governed
 *   voting:   permissionless + GASLESS                 — voter signs, relayer pays
 *
 * Mirrors the existing deploy_rule_value_boxes.js bootstrap→handoff pattern.
 */
describe('Rule ballotbox family — deploy topology (re-genesis shape)', function () {
  const J = 3; // the Foundational Jurisdiction id
  let deployer, executor, relayer, voter, voter2;
  let forwarder, voteToken, registry, boolBox, medBox, plurBox;

  // the 3 FJ-style rules, each on the structure that tallies it
  const ruleUseRealDemocracy = ethers.id('use_real_democracy'); // boolean
  const ruleQuorumThreshold = ethers.id('quorum_threshold');    // median (manipulation-resistant)
  const ruleTallyMode = ethers.id('tally_mode');                // plurality

  // sign a vote with the voter's CURRENT nonce and relay it through the shared gas-payer
  async function relayVote(from, box, ruleKey, tokenId, ballot) {
    const data = box.interface.encodeFunctionData('castVote', [ruleKey, tokenId, ballot]);
    const to = await box.getAddress();
    const nonce = await forwarder.getNonce(from.address);
    const req = { from: from.address, to, value: 0, gas: 1_000_000, nonce, data };
    const net = await ethers.provider.getNetwork();
    const domain = { name: 'MinimalForwarder', version: '0.0.1', chainId: net.chainId, verifyingContract: await forwarder.getAddress() };
    const types = { ForwardRequest: [
      { name: 'from', type: 'address' }, { name: 'to', type: 'address' },
      { name: 'value', type: 'uint256' }, { name: 'gas', type: 'uint256' },
      { name: 'nonce', type: 'uint256' }, { name: 'data', type: 'bytes' },
    ]};
    const signature = await from.signTypedData(domain, types, req);
    await forwarder.connect(relayer).execute(req, signature);
  }

  beforeEach(async function () {
    [deployer, executor, relayer, voter, voter2] = await ethers.getSigners();

    // --- infra: one forwarder, one registry ---
    forwarder = await (await ethers.getContractFactory('SharedGasPayerForwarder')).deploy();
    voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    await Promise.all([forwarder.waitForDeployment(), voteToken.waitForDeployment()]);
    await voteToken.mint(voter.address, 1, J);
    await voteToken.mint(voter2.address, 2, J);

    registry = await (await ethers.getContractFactory('JurisdictionRuleRegistry')).deploy(deployer.address);
    await registry.waitForDeployment();

    const vt = await voteToken.getAddress();
    const fwd = await forwarder.getAddress();

    // --- per-jurisdiction structure boxes (deployer = bootstrap governor) ---
    boolBox = await (await ethers.getContractFactory('BooleanRuleBallotBox')).deploy(vt, J, deployer.address, ethers.ZeroAddress, 6000, fwd);
    medBox = await (await ethers.getContractFactory('MedianRuleBallotBox')).deploy(vt, J, deployer.address, ethers.ZeroAddress, 5000, fwd);
    plurBox = await (await ethers.getContractFactory('PluralityRuleBallotBox')).deploy(vt, J, deployer.address, ethers.ZeroAddress, 5000, fwd);
    await Promise.all([boolBox.waitForDeployment(), medBox.waitForDeployment(), plurBox.waitForDeployment()]);

    // --- bootstrap: register each rule on its structure, bind in the registry ---
    await boolBox.registerRule(ruleUseRealDemocracy, ethers.ZeroHash, '0x');
    await medBox.registerRule(ruleQuorumThreshold, ethers.ZeroHash, ethers.AbiCoder.defaultAbiCoder().encode(['uint16'], [100]));
    await plurBox.registerRule(ruleTallyMode, ethers.ZeroHash, ethers.AbiCoder.defaultAbiCoder().encode(['uint16'], [3]));
    await registry.bindRuleBox(J, ruleUseRealDemocracy, await boolBox.getAddress());
    await registry.bindRuleBox(J, ruleQuorumThreshold, await medBox.getAddress());
    await registry.bindRuleBox(J, ruleTallyMode, await plurBox.getAddress());

    // --- handoff: governorship of each box + the registry's jurisdiction authority → executor ---
    await boolBox.updateGovernor(executor.address);
    await medBox.updateGovernor(executor.address);
    await plurBox.updateGovernor(executor.address);
    await registry.setJurisdictionGovernor(J, executor.address);
  });

  it('stands up the whole topology; voting is permissionless + gasless, read via the registry', async function () {
    // gasless votes — voters sign, the shared relayer submits + pays
    const voterBalBefore = await ethers.provider.getBalance(voter.address);
    await relayVote(voter, boolBox, ruleUseRealDemocracy, 1, [1]);   // support
    await relayVote(voter2, boolBox, ruleUseRealDemocracy, 2, [1]);  // support
    await relayVote(voter, medBox, ruleQuorumThreshold, 1, [60]);
    await relayVote(voter2, medBox, ruleQuorumThreshold, 2, [40]);
    await relayVote(voter, plurBox, ruleTallyMode, 1, [1]);
    await relayVote(voter2, plurBox, ruleTallyMode, 2, [1]);
    expect(await ethers.provider.getBalance(voter.address)).to.equal(voterBalBefore); // gasless

    const decl = await registry.resultFor(J, ruleUseRealDemocracy);
    const quorum = await registry.resultFor(J, ruleQuorumThreshold);
    const tally = await registry.resultFor(J, ruleTallyMode);
    expect(decl.value).to.equal(10000n);  // 100% support
    expect(quorum.value).to.equal(40n);    // lower median of [60,40]
    expect(tally.value).to.equal(1n);      // choice 1
  });

  it('after handoff, ONLY the executor governs rule config — deployer is locked out', async function () {
    const newRule = ethers.id('a_new_rule');
    // bootstrap deployer can no longer register on the box
    await expect(boolBox.registerRule(newRule, ethers.ZeroHash, '0x')).to.be.revertedWith('RuleBox: only governor');
    // the executor (the democratic authority) can
    await boolBox.connect(executor).registerRule(newRule, ethers.ZeroHash, '0x');
    expect((await boolBox.ruleMeta(newRule)).exists).to.equal(true);

    // registry binding authority also moved to the executor
    await expect(registry.connect(voter).bindRuleBox(J, newRule, await boolBox.getAddress()))
      .to.be.revertedWithCustomError(registry, 'NotAuthorized');
    await registry.connect(executor).bindRuleBox(J, newRule, await boolBox.getAddress());
    expect(await registry.boxFor(J, newRule)).to.equal(await boolBox.getAddress());
  });
});
