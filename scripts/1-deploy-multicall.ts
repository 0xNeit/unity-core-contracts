import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();
  console.log("Deploying multicall with address:", deployerAddress);

  const multicall = await ethers.getContractFactory("Multicall3");
  const contract = await multicall.deploy();

  await contract.deployed();

  console.log("Multicall deployed at", contract.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
