const hre = require("hardhat");
const fs = require("fs");
const path = require("path");
const { buildPtsDeploymentProof } = require('./lib/pts_deployment_proof');

const isTruthy = (value) => {
  if (value === undefined || value === null) return false;
  return ["1", "true", "yes", "y", "on"].includes(String(value).toLowerCase().trim());
};

async function main() {
  console.log("=== LIQUID DEMOCRACY VOTING SYSTEM DEPLOYMENT ===\n");
  const { ethers } = hre;
  const [deployer] = await ethers.getSigners();
  console.log(`Deploying contracts with account: ${deployer.address}\n`);

  const shouldDeployChainClock = isTruthy(process.env.DEPLOY_CHAIN_CLOCK ?? process.env.CHAIN_CLOCK_ENABLED);
  const jurisdictionGovernorOverride = (process.env.JURISDICTION_BALLOT_GOVERNOR || '').trim();
  const ptsBaseUri = (process.env.PTS_1155_BASE_URI || 'ipfs://jurisdiction-pts/{id}.json').trim();

  // ── Continuity reuse-guard ──────────────────────────────────────────────────
  // Do NOT redeploy the core suite onto a chain that already has it: a fresh deploy
  // mints NEW contract addresses and ORPHANS every token / PTS / role already minted
  // against the live contracts (a non-nuke `start dev --full` hit exactly this — the
  // electorate stranded on the previous VoteToken). Keyed on on-chain CODE, not a flag,
  // so it's correct for both paths: a re-genesis wipes the chain (prod runbook §3) →
  // the manifest's address has no code there → deploys fresh as intended; a persistent
  // dev chain has code at that address → reuses it. Force a fresh deploy by nuking the
  // chain (or clearing the deployments file).
  {
    const reuseFile = (process.env.DEPLOYMENTS_FILE || process.env.DEPLOYMENTS_PATH
      || (hre.network.name === 'besu' ? 'deployments.json' : 'deployments.dev.json')).trim();
    const reusePath = path.isAbsolute(reuseFile) ? reuseFile : path.resolve(process.cwd(), reuseFile);
    let reuseExisting = null;
    try { reuseExisting = JSON.parse(fs.readFileSync(reusePath, 'utf8')); } catch { reuseExisting = null; }
    if (reuseExisting && reuseExisting.voteToken) {
      const liveCode = await ethers.provider.getCode(reuseExisting.voteToken);
      if (liveCode && liveCode !== '0x') {
        console.log(`↻ Core suite already live on-chain (VoteToken ${reuseExisting.voteToken} has code) — REUSING.`);
        console.log(`  Skipping core redeploy so existing tokens/PTS/roles are not orphaned.`);
        console.log(`  Force a fresh deploy by nuking the chain or clearing ${reuseFile}.`);
        return;
      }
    }
  }

  // 1. Deploy VoteToken
  console.log("1. Deploying VoteToken...");
  const VoteToken = await ethers.getContractFactory("VoteToken");
  const voteToken = await VoteToken.deploy();
  await voteToken.waitForDeployment();
  const voteTokenAddress = await voteToken.getAddress();
  console.log(`   ✓ VoteToken deployed to: ${voteTokenAddress}\n`);

  // 2. Deploy ProposalManager
  console.log("2. Deploying ProposalManager...");
  const ProposalManager = await ethers.getContractFactory("ProposalManager");
  const proposalManager = await ProposalManager.deploy(voteTokenAddress);
  await proposalManager.waitForDeployment();
  const proposalManagerAddress = await proposalManager.getAddress();
  console.log(`   ✓ ProposalManager deployed to: ${proposalManagerAddress}\n`);

  // 3. DelegationRegistry (V1) RETIRED at the re-genesis (#343 item 5). It predates open delegate
  //    voting; the current model is "the delegate signals their vote to the chain IN THE OPEN" via
  //    PublicDelegateVoteRegistry (deployed by deploy_public_delegate_registry.js, on the pipeline). No
  //    separate delegation registry is deployed. (Backend work-order: drop the `delegationRegistry`
  //    read from config/contracts.js.)

  // 4. Deploy VoteTokenMinter (supports legacy + soulbound helpers)
  console.log("4. Deploying VoteTokenMinter...");
  const VoteTokenMinter = await ethers.getContractFactory("VoteTokenMinter");
  const constructorFragment = Array.isArray(VoteTokenMinter.interface?.fragments)
    ? VoteTokenMinter.interface.fragments.find((fragment) => fragment.type === 'constructor')
    : undefined;
  const deployInputs = Array.isArray(constructorFragment?.inputs) ? constructorFragment.inputs : [];
  const isAccessControlMinter = deployInputs.length >= 3;
  const voteTokenMinterAdmin = isAccessControlMinter ? deployer.address : proposalManagerAddress;

  const voteTokenMinterArgs = isAccessControlMinter
    ? [voteTokenAddress, proposalManagerAddress, voteTokenMinterAdmin]
    : [voteTokenAddress, voteTokenMinterAdmin];

  const voteTokenMinter = await VoteTokenMinter.deploy(...voteTokenMinterArgs);
  await voteTokenMinter.waitForDeployment();
  const voteTokenMinterAddress = await voteTokenMinter.getAddress();
  console.log(`   ✓ VoteTokenMinter deployed to: ${voteTokenMinterAddress}\n`);

  if (isAccessControlMinter) {
    console.log(`   ✓ VoteTokenMinter ISSUER_ROLE + DEFAULT_ADMIN_ROLE assigned to ${voteTokenMinterAdmin}\n`);
  }

  // 5. Deploy CheckpointRegistry (for Merkle checkpoint anchoring)
  console.log("5. Deploying CheckpointRegistry...");
  const CheckpointRegistry = await ethers.getContractFactory("CheckpointRegistry");
  const checkpointRegistry = await CheckpointRegistry.deploy();
  await checkpointRegistry.waitForDeployment();
  const checkpointRegistryAddress = await checkpointRegistry.getAddress();
  console.log(`   ✓ CheckpointRegistry deployed to: ${checkpointRegistryAddress}\n`);

  // 5b. Deploy jurisdiction-scoped PTS bank (ERC1155)
  console.log("5b. Deploying JurisdictionPts1155Bank...");
  const JurisdictionPts1155Bank = await ethers.getContractFactory("JurisdictionPts1155Bank");
  const ptsBank1155 = await JurisdictionPts1155Bank.deploy(
    deployer.address,
    voteTokenAddress,
    ptsBaseUri
  );
  await ptsBank1155.waitForDeployment();
  const ptsBank1155Address = await ptsBank1155.getAddress();
  const ptsBank1155Deployment = await buildPtsDeploymentProof({
    ethers, provider: ethers.provider, contract: ptsBank1155
  });
  console.log(`   ✓ JurisdictionPts1155Bank deployed to: ${ptsBank1155Address}\n`);

  // 6. Configure VoteToken authorization / roles
  console.log("6. Configuring VoteToken authorization...");
  const hasAccessControlRoles = typeof voteToken.CUSTODIAN_ROLE === 'function';

  if (hasAccessControlRoles) {
    // New soulbound VoteToken with AccessControl roles
    const custodianRole = await voteToken.CUSTODIAN_ROLE();
    const adminRole = await voteToken.ADMIN_ROLE();

    await (await voteToken.grantRole(custodianRole, voteTokenMinterAddress)).wait();
    console.log(`   ✓ Granted CUSTODIAN_ROLE to VoteTokenMinter`);

    if (proposalManagerAddress) {
      await (await voteToken.grantRole(adminRole, proposalManagerAddress)).wait();
      console.log(`   ✓ Granted ADMIN_ROLE to ProposalManager`);
    }

    // Ensure deployer retains DEFAULT_ADMIN_ROLE to manage future custodians backend-side
    console.log(`   ✓ Role configuration complete\n`);
  } else {
    // Legacy VoteToken (Ownable) flow
    try {
      if (typeof voteToken.authorizeMinter === 'function') {
        await voteToken.authorizeMinter(voteTokenMinterAddress, true);
        console.log(`   ✓ VoteTokenMinter authorized to mint tokens`);
      } else {
        console.log('   ⚠️ voteToken.authorizeMinter not present - skipping authorization');
      }
    } catch (e) {
      console.warn('   ⚠️ authorizeMinter call failed (possibly removed). Continuing deployment. Error:', e.message);
    }

    if (typeof voteToken.transferOwnership === 'function') {
      await (await voteToken.transferOwnership(proposalManagerAddress)).wait();
      console.log(`   ✓ VoteToken ownership transferred to ProposalManager\n`);
    } else {
      console.log('   ⚠️ voteToken.transferOwnership not present - assuming role-based control\n');
    }
  }

  let chainClockAddress = null;
  let jurisdictionFactoryAddress = null;

  if (shouldDeployChainClock) {
    console.log("7. Deploying ChainClock...");
    const ChainClock = await ethers.getContractFactory("ChainClock");
    const chainClock = await ChainClock.deploy(voteTokenAddress, checkpointRegistryAddress);
    await chainClock.waitForDeployment();
    chainClockAddress = await chainClock.getAddress();
    console.log(`   ✓ ChainClock deployed to: ${chainClockAddress}\n`);
  } else {
    console.log("7. ChainClock deployment skipped (DEPLOY_CHAIN_CLOCK not enabled).\n");
  }

  if (chainClockAddress) {
    console.log("8. Deploying JurisdictionFactory...");
    const JurisdictionFactory = await ethers.getContractFactory("JurisdictionFactory");
    const ballotGovernor = jurisdictionGovernorOverride || proposalManagerAddress || deployer.address;
    const jurisdictionFactory = await JurisdictionFactory.deploy(
      voteTokenAddress,
      chainClockAddress,
      ballotGovernor,
      ptsBank1155Address
    );
    await jurisdictionFactory.waitForDeployment();
    jurisdictionFactoryAddress = await jurisdictionFactory.getAddress();
    console.log(`   ✓ JurisdictionFactory deployed to: ${jurisdictionFactoryAddress}`);
    console.log(`   ✓ Ballot governor: ${ballotGovernor}\n`);

    const factoryRole = await ptsBank1155.JURISDICTION_FACTORY_ROLE();
    const hasFactoryRole = await ptsBank1155.hasRole(factoryRole, jurisdictionFactoryAddress);
    if (!hasFactoryRole) {
      await (await ptsBank1155.grantRole(factoryRole, jurisdictionFactoryAddress)).wait();
      console.log("   ✓ Granted JURISDICTION_FACTORY_ROLE to JurisdictionFactory\n");
    }
  } else {
    console.log("8. JurisdictionFactory deployment skipped (ChainClock unavailable).\n");
  }

  // 9. Summary
  console.log("=== DEPLOYMENT SUMMARY ===\n");
  console.log(`Network: ${hre.network.name}`);
  console.log(`Deployer: ${deployer.address}\n`);
  console.log(`Contract Addresses:`);
  console.log(`  VoteToken:           ${voteTokenAddress}`);
  console.log(`  ProposalManager:     ${proposalManagerAddress}`);
  console.log(`  VoteTokenMinter:     ${voteTokenMinterAddress}`);
  console.log(`  CheckpointRegistry:  ${checkpointRegistryAddress}`);
  console.log(`  PtsBank1155:         ${ptsBank1155Address}`);
  if (chainClockAddress) {
    console.log(`  ChainClock:          ${chainClockAddress}`);
  }
  if (jurisdictionFactoryAddress) {
    console.log(`  JurisdictionFactory: ${jurisdictionFactoryAddress}`);
  }
  console.log('');

  console.log("=== READY FOR TESTING ===");
  console.log("Use these addresses in your test harness or backend API.\n");

  // Save addresses to file for frontend/backend use
  const addresses = {
    voteToken: voteTokenAddress,
    proposalManager: proposalManagerAddress,
    voteTokenMinter: voteTokenMinterAddress,
    voteTokenMinterAdmin,
    voteTokenMinterSupportsBackendRole: isAccessControlMinter,
    checkpointRegistry: checkpointRegistryAddress,
    ptsBank1155: ptsBank1155Address,
    ptsBank1155Deployment,
    chainClock: chainClockAddress,
    jurisdictionFactory: jurisdictionFactoryAddress,
    voteTokenHasAccessControl: hasAccessControlRoles,
    deployer: deployer.address,
    network: hre.network.name,
    timestamp: new Date().toISOString(),
  };

  // Default to deployments.dev.json for Hardhat networks, deployments.json for Besu/production.
  // Prevents dev deployments from silently overwriting the prod deployments file.
  const _networkName = hre.network.name;
  const _defaultDeploymentsFile = (_networkName === 'besu') ? 'deployments.json' : 'deployments.dev.json';
  const deploymentsFile = (process.env.DEPLOYMENTS_FILE || process.env.DEPLOYMENTS_PATH || _defaultDeploymentsFile).trim() || _defaultDeploymentsFile;
  const deploymentsOutputPath = path.isAbsolute(deploymentsFile)
    ? deploymentsFile
    : path.resolve(process.cwd(), deploymentsFile);

  fs.writeFileSync(
    deploymentsOutputPath,
    JSON.stringify(addresses, null, 2)
  );
  console.log(`✓ Deployment addresses saved to ${deploymentsOutputPath}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
