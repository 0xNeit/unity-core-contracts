import { ethers } from "hardhat";
import { ADMIN } from "./constants";

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();
  console.log("Deploying UAI Token with address:", deployerAddress);

  const uai = await ethers.getContractFactory("UAI");
  const contract = await uai.deploy(1116);

  await contract.deployed();

  console.log("UAI Token deployed at", contract.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
});
