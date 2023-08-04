import { ethers } from "hardhat";
import { ADMIN } from "./constants";

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();
  console.log("Deploying Interest Rate Model with address:", deployerAddress);

  const irm = await ethers.getContractFactory("JumpRateModel");

  const base = "20000000000000000";
  const slope = "200000000000000000";
  const jump = "2000000000000000000";
  const kink = "900000000000000000";

  const contract = await irm.deploy(base, slope, jump, kink);

  await contract.deployed();

  console.log("Jump Interest Rate Model deployed at", contract.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
});
