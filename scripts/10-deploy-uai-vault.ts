import { ethers } from "hardhat";

require("dotenv").config();


async function main() {
  const uaiVault = await ethers.getContractFactory("UAIVault");
  const uaiVaultImpl = await uaiVault.deploy();
  await uaiVaultImpl.deployed();

  console.log("UAI Vault deployed to:", uaiVaultImpl.address);

  const uaiVaultProxyFactory = await ethers.getContractFactory("UAIVaultProxy");

  // Mainnet
  const uaiVaultProxy = await uaiVaultProxyFactory.deploy();

  await uaiVaultProxy.deployed();
  console.log("UAI Vault Proxy deployed at ", uaiVaultProxy.address);

  const vaultProxy = await ethers.getContractAt(
    "UAIVaultProxy",
    uaiVaultProxy.address
  );

  const vault = await ethers.getContractAt(
    "UAIVault",
    uaiVaultImpl.address
  );

  await vaultProxy._setPendingImplementation(uaiVaultImpl.address);

  console.log("Vault Proxy implementation requested");

  await vault._become(uaiVaultProxy.address);

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
