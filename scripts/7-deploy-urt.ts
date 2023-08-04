import { ethers } from "hardhat";
import { ADMIN } from "./constants";

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();
  console.log("Deploying URT Token with address:", deployerAddress);

  const urt = await ethers.getContractFactory("URT");
  const contract = await urt.deploy(ADMIN);

  await contract.deployed();

  console.log("URT Token deployed at", contract.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
});
