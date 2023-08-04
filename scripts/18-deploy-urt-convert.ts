import { ethers } from "hardhat";

require("dotenv").config();


async function main() {
  const urtConverter = await ethers.getContractFactory("URTConverter");
  const urtConverterImpl = await urtConverter.deploy();
  await urtConverterImpl.deployed();

  console.log("URT Converter deployed to:", urtConverterImpl.address);

  const urtConverterProxyFactory = await ethers.getContractFactory("URTConverterProxy");

  // Mainnet
  const urtConverterProxy = await urtConverterProxyFactory.deploy("x","x","x", 0, 0, 0);

  await urtConverterProxy.deployed();
  console.log("UAI Vault Proxy deployed at ", urtConverterProxy.address);

  const vaultProxy = await ethers.getContractAt(
    "UAIVaultProxy",
    urtConverterProxy.address
  );

  const vault = await ethers.getContractAt(
    "UAIVault",
    urtConverterImpl.address
  );

  await vaultProxy._setPendingImplementation(urtConverterImpl.address);

  console.log("Vault Proxy implementation requested");

  await vault._become(urtConverterProxy.address);

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
