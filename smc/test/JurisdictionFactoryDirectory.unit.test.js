const { expect } = require('chai');
const { ethers } = require('hardhat');

// #343 Steps B + D: the JurisdictionFactory becomes the per-jurisdiction box DIRECTORY, retires the
// legacy per-jurisdiction RuleBallotBox (rules live in the B.2 family / JurisdictionRuleRegistry), and
// gains an additive, default-OFF democratic-creation hook (PERMIT_JURISDICTION_CREATION).
describe('JurisdictionFactory — box directory + legacy-rule-box retirement + creation hook (#343)', function () {
  const Z = ethers.ZeroAddress;
  let deployer, outsider, voteToken, factory;

  beforeEach(async function () {
    [deployer, outsider] = await ethers.getSigners();
    voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    factory = await (await ethers.getContractFactory('JurisdictionFactory')).deploy(
      await voteToken.getAddress(), Z, deployer.address, Z,
    );
  });

  const create = (jid) => factory.createJurisdiction(jid, ethers.ZeroHash, ethers.ZeroHash, 6000, 6000, 3000, [], []);

  it('retires the legacy rule box (record.ruleBallotBox == address(0)) but creates the tag box', async function () {
    await create(11);
    const rec = await factory.jurisdictions(11);
    expect(rec.ruleBallotBox).to.equal(Z);              // #343 item 4 — legacy rule box gone
    expect(rec.tagBallotBox).to.not.equal(Z);
  });

  it('registers the tag box in the on-chain directory at creation', async function () {
    await create(12);
    const rec = await factory.jurisdictions(12);
    const kindTag = await factory.BOX_KIND_TAG();
    expect(await factory.boxOfKind(12, kindTag)).to.equal(rec.tagBallotBox);
  });

  it('createJurisdictionWithReserved seeds reserved governance-domain tags reserved=true + non-votable (#343 edge #1)', async function () {
    const topic = ethers.id('Lighting');
    const reservedTag = ethers.id('tag_governance');
    await factory.createJurisdictionWithReserved(
      16, ethers.ZeroHash, ethers.ZeroHash, 6000, 3000, 1500,
      [topic, reservedTag],
      [ethers.ZeroHash, ethers.ZeroHash],
      [false, true], // topic non-reserved; governance-domain reserved
    );
    const tagBox = await ethers.getContractAt('TagBallotBox', (await factory.jurisdictions(16)).tagBallotBox);
    expect(await tagBox.tagExists(topic)).to.equal(true);
    expect(await tagBox.tagExists(reservedTag)).to.equal(true);
    expect((await tagBox.tags(topic)).reserved).to.equal(false);
    expect((await tagBox.tags(reservedTag)).reserved).to.equal(true);
    // reserved tag is exempt from the existence vote
    await tagBox.setTransparentVotingDisabled(false);
    await voteToken.mint(outsider.address, 1, 16);
    await expect(tagBox.connect(outsider).castVote(reservedTag, 1, [1]))
      .to.be.revertedWith('TagBox: reserved tag not votable');
  });

  it('createJurisdictionWithReserved rejects a misaligned reserved array', async function () {
    await expect(factory.createJurisdictionWithReserved(
      17, ethers.ZeroHash, ethers.ZeroHash, 6000, 3000, 1500,
      [ethers.id('a'), ethers.id('b')],
      [ethers.ZeroHash, ethers.ZeroHash],
      [true], // length 1 != 2 keys
    )).to.be.revertedWith('JurisdictionFactory: tag reserved mismatch');
  });

  it('registerJurisdictionBox enumerates role/initiative/rule-registry boxes (onlyOwner)', async function () {
    await create(13);
    const kindRole = await factory.BOX_KIND_ROLE();
    const fake = outsider.address; // any address — directory is an enumeration, not validated here
    await expect(factory.connect(outsider).registerJurisdictionBox(13, kindRole, fake))
      .to.be.revertedWith('JurisdictionFactory: only owner');
    await expect(factory.registerJurisdictionBox(13, kindRole, fake))
      .to.emit(factory, 'JurisdictionBoxRegistered').withArgs(13, kindRole, fake);
    expect(await factory.boxOfKind(13, kindRole)).to.equal(fake);
  });

  it('registerJurisdictionBox works BEFORE the factory record exists (cut ordering: role/initiative boxes deploy pre-publish)', async function () {
    const kindRole = await factory.BOX_KIND_ROLE();
    // jurisdiction 42 not created yet — directory registration still succeeds (pure enumeration)
    await expect(factory.registerJurisdictionBox(42, kindRole, outsider.address))
      .to.emit(factory, 'JurisdictionBoxRegistered').withArgs(42, kindRole, outsider.address);
    expect(await factory.boxOfKind(42, kindRole)).to.equal(outsider.address);
    // but a zero jurisdiction id is still rejected
    await expect(factory.registerJurisdictionBox(0, kindRole, outsider.address))
      .to.be.revertedWith('JurisdictionFactory: jurisdiction required');
  });

  describe('Step D — democratic creation hook (additive, default OFF)', function () {
    it('owner can always create (the re-genesis-cut path, unchanged)', async function () {
      await expect(create(14)).to.not.be.reverted;
    });

    it('a non-owner is rejected when democratic creation is not configured', async function () {
      await expect(
        factory.connect(outsider).createJurisdiction(15, ethers.ZeroHash, ethers.ZeroHash, 6000, 6000, 3000, [], [])
      ).to.be.revertedWith('JurisdictionFactory: democratic creation not configured');
    });

    it('setCreatorResolver / setFoundationalJurisdictionId are onlyOwner', async function () {
      await expect(factory.connect(outsider).setCreatorResolver(outsider.address))
        .to.be.revertedWith('JurisdictionFactory: only owner');
      await expect(factory.connect(outsider).setFoundationalJurisdictionId(1))
        .to.be.revertedWith('JurisdictionFactory: only owner');
    });
  });
});
