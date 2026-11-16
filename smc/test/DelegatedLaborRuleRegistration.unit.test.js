const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('JurisdictionGovernanceExecutor — delegated Labor Rule registration', function () {
  const JURISDICTION_ID = 14;
  const OTHER_JURISDICTION_ID = 15;
  const ADMIN_ROLE_ID = 1;
  const TOKEN_ADMIN = 1;
  const TOKEN_VOTER = 2;
  const CAP_LABOR_REGISTRATION = ethers.id('permit_labor_rule_registration');
  const CAP_TAG_REGISTRATION = ethers.id('permit_governance_tag_registration');
  const TAG_KEY = ethers.id('labor_scoring');
  const NEW_TAG_KEY = ethers.id('Model Labor');
  const RULE_KEY = ethers.id('labor-rate:general:v1');

  let deployer;
  let admin;
  let voter;
  let voteToken;
  let executor;
  let forwarder;
  let averageBox;
  let tagBox;
  let ruleRegistry;
  let roleCatalog;
  let roleRegistry;
  let capabilityRegistry;

  beforeEach(async function () {
    [deployer, admin, voter] = await ethers.getSigners();

    voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    await voteToken.waitForDeployment();
    await voteToken.mint(admin.address, TOKEN_ADMIN, JURISDICTION_ID);
    await voteToken.mint(voter.address, TOKEN_VOTER, JURISDICTION_ID);

    const factory = await (await ethers.getContractFactory('JurisdictionFactory')).deploy(
      await voteToken.getAddress(),
      ethers.ZeroAddress,
      deployer.address,
      ethers.ZeroAddress,
    );
    await factory.waitForDeployment();

    executor = await (await ethers.getContractFactory('JurisdictionGovernanceExecutor')).deploy(
      await voteToken.getAddress(),
      await factory.getAddress(),
      0,
    );
    await executor.waitForDeployment();
    forwarder = await (await ethers.getContractFactory('SharedGasPayerForwarder')).deploy();
    await forwarder.waitForDeployment();

    averageBox = await (await ethers.getContractFactory('AverageRuleBallotBox')).deploy(
      await voteToken.getAddress(),
      JURISDICTION_ID,
      await executor.getAddress(),
      ethers.ZeroAddress,
      6000,
      ethers.ZeroAddress,
    );
    await averageBox.waitForDeployment();

    tagBox = await (await ethers.getContractFactory('TagBallotBox')).deploy(
      await voteToken.getAddress(),
      JURISDICTION_ID,
      deployer.address,
      ethers.ZeroAddress,
      ethers.ZeroAddress,
      6000,
      4000,
    );
    await tagBox.waitForDeployment();
    await tagBox.registerTag(TAG_KEY, ethers.id('Labor scoring'), true, false);

    ruleRegistry = await (await ethers.getContractFactory('JurisdictionRuleRegistry')).deploy(deployer.address);
    await ruleRegistry.waitForDeployment();
    await ruleRegistry.setJurisdictionGovernor(JURISDICTION_ID, await executor.getAddress());

    roleCatalog = await (await ethers.getContractFactory('RoleCatalog')).deploy(deployer.address);
    await roleCatalog.waitForDeployment();
    roleRegistry = await (await ethers.getContractFactory('JurisdictionRoleRegistry')).deploy(
      await roleCatalog.getAddress(),
      deployer.address,
    );
    await roleRegistry.waitForDeployment();
    capabilityRegistry = await (await ethers.getContractFactory('CapabilityRegistry')).deploy(
      await roleCatalog.getAddress(),
      await roleRegistry.getAddress(),
      deployer.address,
    );
    await capabilityRegistry.waitForDeployment();

    await roleCatalog.defineRole(JURISDICTION_ID, ADMIN_ROLE_ID, 'admin', 'Admin', ethers.ZeroHash);
    await roleCatalog.addCapability(
      JURISDICTION_ID,
      ADMIN_ROLE_ID,
      CAP_LABOR_REGISTRATION,
      'permit_labor_rule_registration',
    );
    await roleCatalog.addCapability(
      JURISDICTION_ID,
      ADMIN_ROLE_ID,
      CAP_TAG_REGISTRATION,
      'permit_governance_tag_registration',
    );
    await roleRegistry.grantRoles(
      JURISDICTION_ID,
      await voteToken.voterIdOf(TOKEN_ADMIN),
      [ADMIN_ROLE_ID],
    );

    await executor.setCapabilityRegistry(await capabilityRegistry.getAddress());
    await executor.setDelegatedTrustedForwarder(await forwarder.getAddress());
    await executor.setLaborRuleRegistrationPolicy(
      JURISDICTION_ID,
      await averageBox.getAddress(),
      await ruleRegistry.getAddress(),
      await tagBox.getAddress(),
      true,
    );
    await tagBox.updateGovernor(await executor.getAddress());
    await executor.setGovernanceTagRegistrationPolicy(
      JURISDICTION_ID,
      await tagBox.getAddress(),
      true,
    );
  });

  const register = (signer = admin, tokenId = TOKEN_ADMIN, overrides = {}) => executor
    .connect(signer)
    .registerLaborRule(
      overrides.jurisdictionId ?? JURISDICTION_ID,
      tokenId,
      overrides.ruleKey ?? RULE_KEY,
      overrides.metadataHash ?? ethers.id('General Labor v1'),
      overrides.tagKey ?? TAG_KEY,
      overrides.externalNullifier ?? 140001,
    );

  const signForwardRequest = async (signer, data) => {
    const nonce = await forwarder.getNonce(signer.address);
    const request = {
      from: signer.address,
      to: await executor.getAddress(),
      value: 0,
      gas: 2_000_000,
      nonce,
      data,
    };
    const network = await ethers.provider.getNetwork();
    const signature = await signer.signTypedData({
      name: 'MinimalForwarder',
      version: '0.0.1',
      chainId: network.chainId,
      verifyingContract: await forwarder.getAddress(),
    }, {
      ForwardRequest: [
        { name: 'from', type: 'address' },
        { name: 'to', type: 'address' },
        { name: 'value', type: 'uint256' },
        { name: 'gas', type: 'uint256' },
        { name: 'nonce', type: 'uint256' },
        { name: 'data', type: 'bytes' },
      ],
    }, request);
    return { request, signature };
  };

  it('lets a capable role holder atomically register a fixed-range Average Rule', async function () {
    const metadataHash = ethers.id('General Labor v1');
    const tx = await register();

    await expect(tx)
      .to.emit(executor, 'LaborRuleRegistered')
      .withArgs(
        JURISDICTION_ID,
        RULE_KEY,
        await voteToken.voterIdOf(TOKEN_ADMIN),
        TOKEN_ADMIN,
        metadataHash,
        TAG_KEY,
        140001,
        await executor.laborRuleRegistrationFingerprint(JURISDICTION_ID, RULE_KEY),
      );

    expect(await averageBox.maxValueOf(RULE_KEY)).to.equal(1000);
    expect(await averageBox.ruleExternalNullifier(RULE_KEY)).to.equal(140001);
    expect(await ruleRegistry.boxFor(JURISDICTION_ID, RULE_KEY)).to.equal(await averageBox.getAddress());
    expect(await ruleRegistry.tagFor(JURISDICTION_ID, RULE_KEY)).to.equal(TAG_KEY);
  });

  it('denies an ordinary voter when the capability is absent from the voter base role', async function () {
    await expect(register(voter, TOKEN_VOTER)).to.be.revertedWith('Executor: delegated capability denied');
  });

  it('accepts a capable holder through the governed shared gas-payer forwarder', async function () {
    const data = executor.interface.encodeFunctionData('registerLaborRule', [
      JURISDICTION_ID,
      TOKEN_ADMIN,
      RULE_KEY,
      ethers.id('General Labor v1'),
      TAG_KEY,
      140001,
    ]);
    const { request, signature } = await signForwardRequest(admin, data);
    const adminBalanceBefore = await ethers.provider.getBalance(admin.address);

    await expect(forwarder.connect(deployer).execute(request, signature))
      .to.emit(executor, 'LaborRuleRegistered');

    expect(await ethers.provider.getBalance(admin.address)).to.equal(adminBalanceBefore);
    expect(await ruleRegistry.boxFor(JURISDICTION_ID, RULE_KEY)).to.equal(await averageBox.getAddress());
  });

  it('does not trust an unconfigured forwarder to impersonate the token owner', async function () {
    await executor.setDelegatedTrustedForwarder(ethers.ZeroAddress);
    const data = executor.interface.encodeFunctionData('registerLaborRule', [
      JURISDICTION_ID,
      TOKEN_ADMIN,
      RULE_KEY,
      ethers.id('General Labor v1'),
      TAG_KEY,
      140001,
    ]);
    const { request, signature } = await signForwardRequest(admin, data);

    // MinimalForwarder reports the inner failure without reverting its own transaction.
    await forwarder.connect(deployer).execute(request, signature);
    expect(await ruleRegistry.boxFor(JURISDICTION_ID, RULE_KEY)).to.equal(ethers.ZeroAddress);
  });

  it('fails closed until a CapabilityRegistry is wired', async function () {
    await executor.setCapabilityRegistry(ethers.ZeroAddress);
    await expect(register()).to.be.revertedWith('Executor: capability registry required');
  });

  it('removes direct registration immediately when the role is revoked', async function () {
    await roleRegistry.revokeRoles(
      JURISDICTION_ID,
      await voteToken.voterIdOf(TOKEN_ADMIN),
      [ADMIN_ROLE_ID],
    );
    await expect(register()).to.be.revertedWith('Executor: delegated capability denied');
  });

  it('makes exact retries idempotent and rejects conflicting retries', async function () {
    await register();
    expect(await executor.connect(admin).registerLaborRule.staticCall(
      JURISDICTION_ID,
      TOKEN_ADMIN,
      RULE_KEY,
      ethers.id('General Labor v1'),
      TAG_KEY,
      140001,
    )).to.equal(false);
    await expect(register(admin, TOKEN_ADMIN, { metadataHash: ethers.id('Changed metadata') }))
      .to.be.revertedWith('Executor: conflicting labor registration');
  });

  it('will not take over a rule that was already bound outside this lane', async function () {
    const preboundKey = ethers.id('prebound');
    const preboundRegistry = await (await ethers.getContractFactory('JurisdictionRuleRegistry')).deploy(deployer.address);
    await preboundRegistry.bindRuleBox(JURISDICTION_ID, preboundKey, await averageBox.getAddress());
    await preboundRegistry.setJurisdictionGovernor(JURISDICTION_ID, await executor.getAddress());
    await executor.setLaborRuleRegistrationPolicy(
      JURISDICTION_ID,
      await averageBox.getAddress(),
      await preboundRegistry.getAddress(),
      await tagBox.getAddress(),
      true,
    );

    await expect(register(admin, TOKEN_ADMIN, { ruleKey: preboundKey }))
      .to.be.revertedWith('Executor: rule already bound');
  });

  it('lets governance disable the delegated lane without changing role membership', async function () {
    await executor.setLaborRuleRegistrationPolicy(
      JURISDICTION_ID,
      await averageBox.getAddress(),
      await ruleRegistry.getAddress(),
      await tagBox.getAddress(),
      false,
    );
    expect(await capabilityRegistry.hasCapability(
      JURISDICTION_ID,
      await voteToken.voterIdOf(TOKEN_ADMIN),
      CAP_LABOR_REGISTRATION,
    )).to.equal(true);
    await expect(register()).to.be.revertedWith('Executor: labor registration disabled');
  });

  it('rejects policy targets outside the jurisdiction and non-Average structures', async function () {
    const otherAverage = await (await ethers.getContractFactory('AverageRuleBallotBox')).deploy(
      await voteToken.getAddress(),
      OTHER_JURISDICTION_ID,
      await executor.getAddress(),
      ethers.ZeroAddress,
      6000,
      ethers.ZeroAddress,
    );
    await expect(executor.setLaborRuleRegistrationPolicy(
      JURISDICTION_ID,
      await otherAverage.getAddress(),
      await ruleRegistry.getAddress(),
      await tagBox.getAddress(),
      true,
    )).to.be.revertedWith('Executor: average box jurisdiction mismatch');

    const booleanBox = await (await ethers.getContractFactory('BooleanRuleBallotBox')).deploy(
      await voteToken.getAddress(),
      JURISDICTION_ID,
      await executor.getAddress(),
      ethers.ZeroAddress,
      6000,
      ethers.ZeroAddress,
    );
    await expect(executor.setLaborRuleRegistrationPolicy(
      JURISDICTION_ID,
      await booleanBox.getAddress(),
      await ruleRegistry.getAddress(),
      await tagBox.getAddress(),
      true,
    )).to.be.revertedWith('Executor: labor box must be average');
  });

  it('locks lane configuration behind a passed executor action after steward renunciation', async function () {
    await executor.renounceBootstrapSteward();
    await expect(executor.setLaborRuleRegistrationPolicy(
      JURISDICTION_ID,
      await averageBox.getAddress(),
      await ruleRegistry.getAddress(),
      await tagBox.getAddress(),
      false,
    )).to.be.revertedWith('Executor: steward or vote required');

    // Existing, democratically configured policy remains usable by its capable role holder.
    await expect(register()).to.emit(executor, 'LaborRuleRegistered');
  });

  it('registers only a new inactive, non-reserved governance Tag', async function () {
    const metadataHash = ethers.id('Model labor scoring');
    const tx = await executor.connect(admin).registerGovernanceTag(
      JURISDICTION_ID,
      TOKEN_ADMIN,
      NEW_TAG_KEY,
      metadataHash,
    );
    await expect(tx).to.emit(executor, 'GovernanceTagRegistered');
    const state = await tagBox.tags(NEW_TAG_KEY);
    expect(state.exists).to.equal(true);
    expect(state.active).to.equal(false);
    expect(state.reserved).to.equal(false);
  });

  it('denies Tag registration without the capability and prevents direct governor writes', async function () {
    await expect(executor.connect(voter).registerGovernanceTag(
      JURISDICTION_ID,
      TOKEN_VOTER,
      NEW_TAG_KEY,
      ethers.id('Model labor scoring'),
    )).to.be.revertedWith('Executor: delegated capability denied');
    await expect(tagBox.connect(admin).registerTag(
      NEW_TAG_KEY,
      ethers.id('Model labor scoring'),
      true,
      true,
    )).to.be.revertedWith('RuleBox: only governor');
  });

  it('makes exact Tag retries idempotent and rejects metadata edits through registration', async function () {
    const metadataHash = ethers.id('Model labor scoring');
    await executor.connect(admin).registerGovernanceTag(
      JURISDICTION_ID, TOKEN_ADMIN, NEW_TAG_KEY, metadataHash,
    );
    expect(await executor.connect(admin).registerGovernanceTag.staticCall(
      JURISDICTION_ID, TOKEN_ADMIN, NEW_TAG_KEY, metadataHash,
    )).to.equal(false);
    await expect(executor.connect(admin).registerGovernanceTag(
      JURISDICTION_ID, TOKEN_ADMIN, NEW_TAG_KEY, ethers.id('Changed metadata'),
    )).to.be.revertedWith('Executor: conflicting tag registration');
  });

  it('will not adopt a Tag registered outside the delegated lane', async function () {
    await expect(executor.connect(admin).registerGovernanceTag(
      JURISDICTION_ID, TOKEN_ADMIN, TAG_KEY, ethers.id('Labor scoring'),
    )).to.be.revertedWith('Executor: tag already registered');
  });

  it('validates and can disable the jurisdiction Tag registration policy', async function () {
    const otherTagBox = await (await ethers.getContractFactory('TagBallotBox')).deploy(
      await voteToken.getAddress(),
      OTHER_JURISDICTION_ID,
      await executor.getAddress(),
      ethers.ZeroAddress,
      ethers.ZeroAddress,
      6000,
      4000,
    );
    await expect(executor.setGovernanceTagRegistrationPolicy(
      JURISDICTION_ID, await otherTagBox.getAddress(), true,
    )).to.be.revertedWith('Executor: tag box jurisdiction mismatch');

    await executor.setGovernanceTagRegistrationPolicy(
      JURISDICTION_ID, await tagBox.getAddress(), false,
    );
    await expect(executor.connect(admin).registerGovernanceTag(
      JURISDICTION_ID, TOKEN_ADMIN, NEW_TAG_KEY, ethers.id('Model labor scoring'),
    )).to.be.revertedWith('Executor: tag registration disabled');
  });
});
