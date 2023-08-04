import { ethers } from "hardhat";

require("dotenv").config();


async function main() {
  const ucoreVault = await ethers.getContractFactory("UCOREVault");
  const ucoreVaultImpl = await ucoreVault.deploy();
  await ucoreVaultImpl.deployed();

  console.log("UCORE Vault deployed to:", ucoreVaultImpl.address);

  const ucoreVaultProxyFactory = await ethers.getContractFactory("UCOREVaultProxy");

  // Mainnet
  const ucoreVaultProxy = await ucoreVaultProxyFactory.deploy();

  await ucoreVaultProxy.deployed();
  console.log("UCORE Vault Proxy deployed at ", ucoreVaultProxy.address);

  const vaultProxy = await ethers.getContractAt(
    "UCOREVaultProxy",
    ucoreVaultProxy.address
  );

  const vault = await ethers.getContractAt(
    "UCOREVault",
    ucoreVaultImpl.address
  );

  await vaultProxy._setPendingImplementation(ucoreVaultImpl.address);

  console.log("Vault Proxy implementation requested");

  await vault._become(ucoreVaultProxy.address);

  console.log("Vault Proxy implementation accepted");
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
