import { ethers } from "hardhat";
import { ADMIN, INTEREST_MODEL, UNITROLLER } from "./constants";

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();
  console.log("Deploying VCORE with address:", deployerAddress);

  const vCORE = await ethers.getContractFactory("VCORE");

  const initial_exchange_rate_mantissa = "20000000000000000";

  const name = "Unity Virtual CORE";
  const symbol = "vCORE";
  const decimals = "8";

  const contract = await vCORE.deploy(
    UNITROLLER, 
    INTEREST_MODEL, 
    initial_exchange_rate_mantissa,
    name,
    symbol,
    decimals,
    ADMIN
);

  await contract.deployed();

  console.log("VCORE deployed at", contract.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
});
