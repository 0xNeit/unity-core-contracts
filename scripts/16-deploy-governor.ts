import { ethers } from "hardhat";
import { ADMIN, UCOREVAULT, TIMELOCK, GOVERNOR } from "./constants";

require("dotenv").config();


async function main() {
  /*const timelock = await ethers.getContractFactory("Timelock");
  const delay = "172800"
  const timelockImpl = await timelock.deploy(ADMIN, delay);
  await timelockImpl.deployed();

  console.log("Timelock Contract deployed at:", timelockImpl.address);*/

  /*const governorBravoDelegate = await ethers.getContractFactory("GovernorBravoDelegate");
  const governorBravoDelegateImpl = await governorBravoDelegate.deploy();
  await governorBravoDelegateImpl.deployed();

  console.log("Governor Bravo Delegate deployed to:", governorBravoDelegateImpl.address);*/

  const governorBravoDelegatorFactory = await ethers.getContractFactory("GovernorBravoDelegator");

  const votingPeriod = "28800"
  const votingDelay = "1"
  const proposalThreshold = "300000000000000000000000"

  // Mainnet
  const governorBravoDelegator = await governorBravoDelegatorFactory.deploy(
    TIMELOCK, 
    UCOREVAULT, 
    ADMIN,
    GOVERNOR,
    votingPeriod,
    votingDelay,
    proposalThreshold,
    ADMIN
  );

  await governorBravoDelegator.deployed();
  console.log("Governor Bravo Delegator deployed at ", governorBravoDelegator.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
