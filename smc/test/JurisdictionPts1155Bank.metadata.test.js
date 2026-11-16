const { expect } = require('chai');
const { ethers } = require('hardhat');

const decodeDataUri = (uri) => {
  expect(uri).to.match(/^data:application\/json;base64,/);
  const b64 = uri.slice('data:application/json;base64,'.length);
  return JSON.parse(Buffer.from(b64, 'base64').toString('utf8'));
};

const decodeSvg = (imageUri) => {
  expect(imageUri).to.match(/^data:image\/svg\+xml;base64,/);
  const b64 = imageUri.slice('data:image/svg+xml;base64,'.length);
  return Buffer.from(b64, 'base64').toString('utf8');
};

describe('JurisdictionPts1155Bank on-chain metadata', function () {
  const JID = 8;
  let deployer;
  let voteToken, catalog, bank;

  beforeEach(async function () {
    [deployer] = await ethers.getSigners();

    voteToken = await (await ethers.getContractFactory('VoteToken')).deploy();
    await voteToken.waitForDeployment();

    catalog = await (await ethers.getContractFactory('RoleCatalog')).deploy(deployer.address);
    await catalog.waitForDeployment();

    bank = await (await ethers.getContractFactory('JurisdictionPts1155Bank'))
      .deploy(deployer.address, await voteToken.getAddress(), 'ipfs://pts/');
    await bank.waitForDeployment();

    await bank.configureJurisdiction(JID, deployer.address, ethers.ZeroAddress);
  });

  it('exposes a collection-level name/symbol', async function () {
    expect(await bank.name()).to.equal('Jurisdiction PTS');
    expect(await bank.symbol()).to.equal('JPTS');
  });

  it('falls back to "Jurisdiction <id> PTS" with the default accent when roleCatalog is unset', async function () {
    const meta = decodeDataUri(await bank.uri(JID));
    expect(meta.name).to.equal(`Jurisdiction ${JID} PTS`);
    const svg = decodeSvg(meta.image);
    expect(svg).to.include('#00ffb2');
    expect(svg).to.include(`Jurisdiction ${JID}`);
  });

  it('names the token after the jurisdiction once roleCatalog is wired', async function () {
    await bank.setRoleCatalog(await catalog.getAddress());
    await catalog.setJurisdictionName(JID, 'Real Democracy');

    const meta = decodeDataUri(await bank.uri(JID));
    expect(meta.name).to.equal('Real Democracy PTS');
    expect(meta.attributes.find((a) => a.trait_type === 'Jurisdiction').value).to.equal('Real Democracy');
  });

  it('lets a jurisdiction governor set a custom accent color, rendered into the badge', async function () {
    await bank.setJurisdictionAccentColor(JID, '#ff00aa');
    const meta = decodeDataUri(await bank.uri(JID));
    const svg = decodeSvg(meta.image);
    expect(svg).to.include('#ff00aa');
    expect(svg).to.not.include('#00ffb2');
  });

  it('rejects accent-color changes from a non-governor, non-admin caller', async function () {
    const [, outsider] = await ethers.getSigners();
    await expect(
      bank.connect(outsider).setJurisdictionAccentColor(JID, '#ff00aa')
    ).to.be.revertedWith('JurisdictionPts1155Bank: governor only');
  });

  it('two jurisdictions render distinct names and images', async function () {
    const JID2 = 9;
    await bank.configureJurisdiction(JID2, deployer.address, ethers.ZeroAddress);
    await bank.setJurisdictionAccentColor(JID2, '#123456');

    await bank.setRoleCatalog(await catalog.getAddress());
    await catalog.setJurisdictionName(JID, 'Real Democracy');
    await catalog.setJurisdictionName(JID2, 'Chicago');

    const meta1 = decodeDataUri(await bank.uri(JID));
    const meta2 = decodeDataUri(await bank.uri(JID2));

    expect(meta1.name).to.equal('Real Democracy PTS');
    expect(meta2.name).to.equal('Chicago PTS');
    expect(meta1.image).to.not.equal(meta2.image);
  });
});
