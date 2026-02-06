const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);

  // Base Sepolia USDC address
  const USDC_ADDRESS = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";

  // 1. Deploy ValidatorRegistry
  const ValidatorRegistry = await hre.ethers.getContractFactory("ValidatorRegistry");
  const validatorRegistry = await ValidatorRegistry.deploy(USDC_ADDRESS);
  await validatorRegistry.waitForDeployment();
  const validatorRegistryAddr = await validatorRegistry.getAddress();
  console.log("ValidatorRegistry deployed to:", validatorRegistryAddr);

  // 2. Deploy InsurancePoolRegistry
  const InsurancePoolRegistry = await hre.ethers.getContractFactory("InsurancePoolRegistry");
  const insurancePoolRegistry = await InsurancePoolRegistry.deploy(USDC_ADDRESS);
  await insurancePoolRegistry.waitForDeployment();
  const insurancePoolRegistryAddr = await insurancePoolRegistry.getAddress();
  console.log("InsurancePoolRegistry deployed to:", insurancePoolRegistryAddr);

  // 3. Deploy ClaimsProcessor
  const ClaimsProcessor = await hre.ethers.getContractFactory("ClaimsProcessor");
  const claimsProcessor = await ClaimsProcessor.deploy(
    USDC_ADDRESS,
    insurancePoolRegistryAddr,
    validatorRegistryAddr
  );
  await claimsProcessor.waitForDeployment();
  const claimsProcessorAddr = await claimsProcessor.getAddress();
  console.log("ClaimsProcessor deployed to:", claimsProcessorAddr);

  // 4. Deploy PolicyManager
  const PolicyManager = await hre.ethers.getContractFactory("PolicyManager");
  const policyManager = await PolicyManager.deploy(USDC_ADDRESS, insurancePoolRegistryAddr);
  await policyManager.waitForDeployment();
  const policyManagerAddr = await policyManager.getAddress();
  console.log("PolicyManager deployed to:", policyManagerAddr);

  // 5. Transfer ownership of InsurancePoolRegistry to PolicyManager
  //    so PolicyManager can call reserveCapacity, releaseCapacity, recordPremium
  console.log("\nConfiguring contract permissions...");
  const tx = await insurancePoolRegistry.transferOwnership(policyManagerAddr);
  await tx.wait();
  console.log("InsurancePoolRegistry ownership transferred to PolicyManager");

  console.log("\n--- Deployment Summary ---");
  console.log("USDC:                  ", USDC_ADDRESS);
  console.log("ValidatorRegistry:     ", validatorRegistryAddr);
  console.log("InsurancePoolRegistry: ", insurancePoolRegistryAddr);
  console.log("ClaimsProcessor:       ", claimsProcessorAddr);
  console.log("PolicyManager:         ", policyManagerAddr);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
