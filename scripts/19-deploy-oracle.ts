import { ethers } from "hardhat";
import { WCORE, VCORE, UAI } from "./constants";

require("dotenv").config();


async function main() {

  const twapOracleIce = await ethers.getContractFactory("TwapOracleIce");
  const twapOracleIceImpl = await twapOracleIce.deploy(WCORE);
  await twapOracleIceImpl.deployed();
  console.log('TWAP Oracle ICE deployed to:', twapOracleIceImpl.address)

  const boundValidator = await ethers.getContractFactory("BoundValidator");
  const boundValidatorImpl = await boundValidator.deploy();
  await boundValidatorImpl.deployed();
  console.log('Bound Validator deployed to:', boundValidatorImpl.address)

  const resilientOracle = await ethers.getContractFactory("ResilientOracle");
  const resilientOracleImpl = await resilientOracle.deploy(VCORE, UAI, boundValidatorImpl.address);
  await resilientOracleImpl.deployed();
  console.log('Resilient Oracle deployed to:', resilientOracleImpl.address)
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
