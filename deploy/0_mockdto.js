const {
  chainNameById,
  chainIdByName,
  saveDeploymentData,
  getContractAbi,
  log
} = require("../js-helpers/deploy");

const _ = require('lodash');
const { BigNumber } = require("@ethersproject/bignumber");
module.exports = async (hre) => {
    const { ethers, upgrades, getNamedAccounts } = hre;
    const { deployer, protocolOwner, trustedForwarder } = await getNamedAccounts();
    const network = await hre.network;
    const deployData = {};

    const chainId = chainIdByName(network.name);

    log('\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~');
    log('DTO Multichain Decentralized Oracle Protocol - Mock DTO Token Contract Deployment');
    log('~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n');

    log('  Using Network: ', chainNameById(chainId));
    log('  Using Accounts:');
    log('  - Deployer:          ', deployer);
    log('  - network id:          ', chainId);
    log('  - Owner:             ', protocolOwner);
    log('  - Trusted Forwarder: ', trustedForwarder);
    log(' ');

    log('  Deploying Mock ERC20...');
    const ERC20Mock = await ethers.getContractFactory('ERC20Mock');
    const ERC20MockInstance = await ERC20Mock.deploy("DTO Faucet", "DTO", deployer, BigNumber.from(10).pow(18).mul('100000000'))
    const dtoMock = await ERC20MockInstance.deployed()
    log('  - DTO Mock Token:         ', dtoMock.address);
    deployData['DTOToken'] = {
      abi: getContractAbi('ERC20Mock'),
      address: dtoMock.address,
      deployTransaction: dtoMock.deployTransaction,
    }

    saveDeploymentData(chainId, deployData);
    log('\n  Contract Deployment Data saved to "deployments" directory.');

    log('\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n');
};

module.exports.tags = ['mockerc20']
