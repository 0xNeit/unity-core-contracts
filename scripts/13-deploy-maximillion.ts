import { ethers } from "hardhat";
import { VCORE } from "./constants";

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();
  console.log("Deploying Maximilion with address:", deployerAddress);

  const mx = await ethers.getContractFactory("Maximillion");
  const contract = await mx.deploy(VCORE);

  await contract.deployed();

  console.log("Maximillion deployed at", contract.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
