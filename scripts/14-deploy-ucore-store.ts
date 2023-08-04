import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();
  console.log("Deploying UCOREStore with address:", deployerAddress);

  const ucstore = await ethers.getContractFactory("UCOREStore");
  const contract = await ucstore.deploy();

  await contract.deployed();

  console.log("UCOREStore deployed at", contract.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
