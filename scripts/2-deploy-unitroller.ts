import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();
  console.log("Deploying unitroller with address:", deployerAddress);

  const unitroller = await ethers.getContractFactory("Unitroller");
  const contract = await unitroller.deploy();

  await contract.deployed();

  console.log("Unitroller deployed at", contract.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
