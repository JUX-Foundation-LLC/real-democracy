const { expect } = require('chai');
const { ethers } = require('hardhat');

// §8c.4 trustless-eligibility bridge: the on-chain home for each VoteToken's zk identity
// commitment, so a ballot's eligibility root is rebuildable from chain alone.
describe('VoteCommitmentRegistry — §8c.4 eligibility bridge', function () {
  let registrar, owner, stranger, registry;
  const J = 4n;
  const TOKEN = 7n;
  // a valid BN254 field element (a realistic Poseidon commitment shape)
  const C1 = 12345678901234567890n;
  const C2 = 98765432109876543210n;
  const FIELD_PRIME =
    21888242871839275222246405745257275088548364400416034343698204186575808495617n;

  beforeEach(async function () {
    [registrar, owner, stranger] = await ethers.getSigners();
    registry = await (await ethers.getContractFactory('VoteCommitmentRegistry')).deploy(registrar.address);
  });

  describe('REGISTRAR publication (bootstrap / custodial)', function () {
    it('publishes a commitment, binds the jurisdiction, and emits with previous=0', async function () {
      await expect(registry.publishCommitment(TOKEN, J, C1))
        .to.emit(registry, 'CommitmentPublished')
        .withArgs(TOKEN, J, C1, 0, registrar.address);
      const [c, j] = await registry.commitmentInfo(TOKEN);
      expect(c).to.equal(C1);
      expect(j).to.equal(J);
    });

    it('rotates the commitment (key change / handover), carrying the previous value', async function () {
      await registry.publishCommitment(TOKEN, J, C1);
      await expect(registry.publishCommitment(TOKEN, J, C2))
        .to.emit(registry, 'CommitmentPublished')
        .withArgs(TOKEN, J, C2, C1, registrar.address);
      expect(await registry.commitmentForToken(TOKEN)).to.equal(C2);
    });

    it('rejects zero token / zero jurisdiction / zero commitment / non-field commitment', async function () {
      await expect(registry.publishCommitment(0, J, C1)).to.be.revertedWithCustomError(registry, 'TokenRequired');
      await expect(registry.publishCommitment(TOKEN, 0, C1)).to.be.revertedWithCustomError(registry, 'JurisdictionRequired');
      await expect(registry.publishCommitment(TOKEN, J, 0)).to.be.revertedWithCustomError(registry, 'CommitmentRequired');
      await expect(registry.publishCommitment(TOKEN, J, FIELD_PRIME))
        .to.be.revertedWithCustomError(registry, 'CommitmentNotFieldElement');
    });

    it('locks the token→jurisdiction binding (a token never migrates jurisdiction)', async function () {
      await registry.publishCommitment(TOKEN, J, C1);
      await expect(registry.publishCommitment(TOKEN, 99, C2))
        .to.be.revertedWithCustomError(registry, 'JurisdictionImmutable')
        .withArgs(TOKEN, J, 99);
    });
  });

  describe('authority', function () {
    it('rejects a non-registrar with no VoteToken wired', async function () {
      await expect(registry.connect(stranger).publishCommitment(TOKEN, J, C1))
        .to.be.revertedWithCustomError(registry, 'NotAuthorized')
        .withArgs(TOKEN, stranger.address);
    });

    it('lets the token OWNER self-publish once a VoteToken is wired; strangers still cannot', async function () {
      const mock = await (await ethers.getContractFactory('MockOwnedVoteToken')).deploy();
      await mock.setOwner(TOKEN, owner.address);
      await mock.setActive(TOKEN, true);
      await registry.setVoteToken(await mock.getAddress());

      await expect(registry.connect(owner).publishCommitment(TOKEN, J, C1))
        .to.emit(registry, 'CommitmentPublished')
        .withArgs(TOKEN, J, C1, 0, owner.address);

      await expect(registry.connect(stranger).publishCommitment(TOKEN, J, C2))
        .to.be.revertedWithCustomError(registry, 'NotAuthorized');
    });

    it('denies owner self-publication for an INACTIVE token', async function () {
      const mock = await (await ethers.getContractFactory('MockOwnedVoteToken')).deploy();
      await mock.setOwner(TOKEN, owner.address);
      await mock.setActive(TOKEN, false);
      await registry.setVoteToken(await mock.getAddress());
      await expect(registry.connect(owner).publishCommitment(TOKEN, J, C1))
        .to.be.revertedWithCustomError(registry, 'NotAuthorized');
    });
  });
});
