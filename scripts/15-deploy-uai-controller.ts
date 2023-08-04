import { ethers } from "hardhat";

require("dotenv").config();


async function main() {

  const uaiController = await ethers.getContractFactory("UAIController");
  const uaiControllerImpl = await uaiController.deploy();
  await uaiControllerImpl.deployed();

  console.log("UAI Controller deployed to:", uaiControllerImpl.address);

  const uaiControllerProxyFactory = await ethers.getContractFactory("UAIUnitroller");

  // Mainnet
  const uaiControllerProxy = await uaiControllerProxyFactory.deploy();

  await uaiControllerProxy.deployed();
  console.log("UAI Unitroller deployed at ", uaiControllerProxy.address);

  const vaultProxy = await ethers.getContractAt(
    "UAIUnitroller",
    uaiControllerProxy.address
  );

  const vault = await ethers.getContractAt(
    "UAIController",
    uaiControllerImpl.address
  );

  await vaultProxy._setPendingImplementation(uaiControllerImpl.address);

  console.log("UAI Unitroller implementation requested");

  await vault._become(uaiControllerProxy.address);

  console.log("UAI Controller implementation accepted");
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
