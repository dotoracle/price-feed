const {
  chainNameById,
  chainIdByName,
  saveDeploymentData,
  getContractAbi,
  log,
  supportedChainIds,
  approvers
} = require("../js-helpers/deploy");

const _ = require('lodash');

module.exports = async (hre) => {
  const { ethers, upgrades, getNamedAccounts } = hre;
  const BigNumber = ethers.BigNumber
  const { deployer, protocolOwner, trustedForwarder, dtoToken } = await getNamedAccounts();
  const network = await hre.network;
  const deployData = {};

  const chainId = chainIdByName(network.name);

  log('\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~');
  log('DTO Multichain Oracle Protocol - Deviation Checker Contract Deployment');
  log('~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n');
  log('  dtoToken: ', dtoToken);

  log('  Using Network: ', chainNameById(chainId));
  log('  Using Accounts:');
  log('  - Deployer:          ', deployer);
  log('  - network id:          ', chainId);
  log('  - Owner:             ', protocolOwner);
  log('  - Trusted Forwarder: ', trustedForwarder);
  log(' ');

  log('  Deploying DeviationChecker...');
  let flagAddress = ethers.constants.AddressZero

  //deploy DeviationChecker
  const DeviationChecker = await ethers.getContractFactory('DeviationChecker')
  const DeviationCheckerInstance = await DeviationChecker.deploy(flagAddress, 5000) //5%
  const deviationChecker = await DeviationCheckerInstance.deployed()
  log('  - DeviationChecker:         ', deviationChecker.address);
  deployData['DeviationChecker'] = {
    abi: getContractAbi('DeviationChecker'),
    address: deviationChecker.address,
    deployTransaction: deviationChecker.deployTransaction,
  }

  saveDeploymentData(chainId, deployData);
  log('\n  Contract Deployment Data saved to "deployments" directory.');

  log('\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n');
};

module.exports.tags = ['pricefeed']
