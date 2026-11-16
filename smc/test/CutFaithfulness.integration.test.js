const { expect } = require('chai');
const { ethers } = require('hardhat');

// §10.3 FAITHFULNESS GATE — integration proof (no docker): the integrated cut path (publish_jurisdictions
// seeding tags + real hashes → family bindRuleBox → bindRuleTag) reproduces the DB exports on-chain for
// every jurisdiction. Mirrors backend buildBootstrapPayloadFromDB's `expected` fingerprint and the
// scripts/verify_cut_faithfulness.js gate, run against a Hardhat node with sample exports.
describe('Cut faithfulness gate (#343/#349) — integrated pipeline reproduces DB exports on-chain', function () {
  const Z = ethers.ZeroAddress;
  const H = ethers.ZeroHash;
  let deployer, alice, voteToken, factory, registry;

  // sample DB exports (the shape export_jurisdictions/export_tags/export_rules emit)
  const tagKey = (name) => ethers.id(name);
  const RSH = '0x' + '11'.repeat(32); // a real (non-zero) FJ ruleSetHash
  const TRH = '0x' + '22'.repeat(32);
  const jurisdictionsExport = [
    { id: 3, code: 'coikat', rule_set_hash: RSH, tag_registry_hash: TRH },
    { id: 7, code: 'demo', rule_set_hash: null, tag_registry_hash: null }, // FJ-less → ZeroHash fallback
  ];
  const tagsExport = [
    { jurisdiction_id: 3, name: 'Lighting', tag_key: tagKey('Lighting'), metadata_hash: H, active: true },
    { jurisdiction_id: 3, name: 'Economics', tag_key: tagKey('Economics'), metadata_hash: H, active: true },
    { jurisdiction_id: 7, name: 'Lighting', tag_key: tagKey('Lighting'), metadata_hash: H, active: true },
  ];
  const rulesExport = [
    { jurisdiction_id: 3, rule_key: 'quorum_threshold', delegation_tag_key: tagKey('Lighting') },
    { jurisdiction_id: 3, rule_key: 'payout_split', delegation_tag_key: tagKey('Economics') },
    { jurisdiction_id: 3, rule_key: 'untagged_rule', delegation_tag_key: null }, // edge: no delegation tag
    { jurisdiction_id: 7, rule_key: 'some_rule', delegation_tag_key: tagKey('Lighting') },
  ];

  before(async function () {
    [deployer, alice] = await ethers.getSigners();
    voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    await voteToken.waitForDeployment();
    factory = await (await ethers.getContractFactory('JurisdictionFactory')).deploy(
      await voteToken.getAddress(), Z, deployer.address, Z,
    );
    await factory.waitForDeployment();
    registry = await (await ethers.getContractFactory('JurisdictionRuleRegistry')).deploy(deployer.address);
    await registry.waitForDeployment();

    const isHash32 = (v) => typeof v === 'string' && ethers.isHexString(v, 32);
    const tagsByJid = (jid) => tagsExport.filter((t) => t.jurisdiction_id === jid);
    const rulesByJid = (jid) => rulesExport.filter((r) => r.jurisdiction_id === jid);

    // --- simulate the integrated pipeline for each jurisdiction ---
    for (const j of jurisdictionsExport) {
      const jid = j.id;
      const rsh = isHash32(j.rule_set_hash) ? j.rule_set_hash : H; // publish_jurisdictions fallback
      const trh = isHash32(j.tag_registry_hash) ? j.tag_registry_hash : H;
      const jtags = tagsByJid(jid);

      // publish_jurisdictions.js: createJurisdiction with REAL hashes + bootstrap tags from export
      await factory.createJurisdiction(
        jid, rsh, trh, 6000, 3000, 1500,
        jtags.map((t) => t.tag_key),
        jtags.map((t) => t.metadata_hash),
      );

      // deploy_rule_ballotbox_family.js: per-jurisdiction structure box + register + bindRuleBox + bindRuleTag
      const box = await (await ethers.getContractFactory('BooleanRuleBallotBox')).deploy(
        await voteToken.getAddress(), jid, deployer.address, Z, 6000, Z,
      );
      await box.waitForDeployment();
      // register the rule registry + tag box in the directory (deploy-script behavior)
      await factory.registerJurisdictionBox(jid, ethers.id('ruleRegistry'), await registry.getAddress());

      const tagBoxAddr = await factory.boxOfKind(jid, ethers.id('tag'));
      for (const r of rulesByJid(jid)) {
        const rk = ethers.id(r.rule_key);
        await box.registerRule(rk, H, '0x');
        await registry.bindRuleBox(jid, rk, await box.getAddress());
        if (r.delegation_tag_key) {
          await registry.bindRuleTag(jid, rk, r.delegation_tag_key, tagBoxAddr); // honors order: tags seeded → bindRuleBox → bindRuleTag
        }
      }
    }
  });

  it('every exported tag exists on its jurisdiction TagBallotBox (TagBallotBoxes are NOT born empty)', async function () {
    for (const j of jurisdictionsExport) {
      const tagBoxAddr = await factory.boxOfKind(j.id, ethers.id('tag'));
      expect(tagBoxAddr).to.not.equal(Z);
      const tagBox = await ethers.getContractAt('TagBallotBox', tagBoxAddr);
      for (const t of tagsExport.filter((x) => x.jurisdiction_id === j.id)) {
        expect(await tagBox.tagExists(t.tag_key), `tag ${t.name} on j${j.id}`).to.equal(true);
      }
    }
  });

  it('every rule→tag delegation binding reproduces on-chain (tagFor == DB delegation tag)', async function () {
    for (const r of rulesExport.filter((x) => x.delegation_tag_key)) {
      const onchain = await registry.tagFor(r.jurisdiction_id, ethers.id(r.rule_key));
      expect(onchain.toLowerCase(), `${r.rule_key}`).to.equal(String(r.delegation_tag_key).toLowerCase());
    }
  });

  it('a rule with no delegation tag stays unbound (tagFor == 0) — single-valued, no spurious bind', async function () {
    const onchain = await registry.tagFor(3, ethers.id('untagged_rule'));
    expect(onchain).to.equal(H);
  });

  it('the REAL FJ snapshot hash is stored (not ZeroHash) when the DB has one', async function () {
    const rec = await factory.jurisdictions(3);
    expect(rec.ruleSetHash).to.equal(RSH);
    expect(rec.tagRegistryHash).to.equal(TRH);
    // and the FJ-less jurisdiction falls back to ZeroHash
    const rec7 = await factory.jurisdictions(7);
    expect(rec7.ruleSetHash).to.equal(H);
  });

  it('the legacy rule box is NOT built (item 4) — record.ruleBallotBox == 0; rules live in the registry', async function () {
    const rec = await factory.jurisdictions(3);
    expect(rec.ruleBallotBox).to.equal(Z);
    expect(await registry.boxFor(3, ethers.id('quorum_threshold'))).to.not.equal(Z);
  });
});
