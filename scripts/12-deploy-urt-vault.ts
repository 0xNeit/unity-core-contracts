import { ethers } from "hardhat";

require("dotenv").config();


async function main() {
  const urtVault = await ethers.getContractFactory("URTVault");
  const urtVaultImpl = await urtVault.deploy();
  await urtVaultImpl.deployed();

  console.log("URT Vault deployed to:", urtVaultImpl.address);

  const urtVaultProxyFactory = await ethers.getContractFactory("URTVaultProxy");

  // Mainnet
  const urtVaultProxy = await urtVaultProxyFactory.deploy(urtVaultImpl.address, "0xd101a592AAd3B38b0546a308d4D761c5d5b1b4F3", "3000000000");

  await urtVaultProxy.deployed();
  console.log("URT Vault Proxy deployed at ", urtVaultProxy.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
