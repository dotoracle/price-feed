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
    log('DTO Multichain Oracle Protocol - Price Feed Contract Deployment');
    log('~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n');

    log('  Using Network: ', chainNameById(chainId));
    log('  Using Accounts:');
    log('  - Deployer:          ', deployer);
    log('  - network id:          ', chainId);
    log('  - Owner:             ', protocolOwner);
    log('  - Trusted Forwarder: ', trustedForwarder);
    log(' ');

    log('  Deploying GenericBridge...');
    let dtoTokenAddress
    if (chainId == 31337) {
      dtoTokenAddress = require(`../deployments/${chainId}/DTOToken.json`).address
    } else {
      dtoTokenAddress = dtoToken.address
    }

    let paymentAmount = BigNumber.from(10).pow(18)
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

    let _minSubmissionValue = BigNumber.from(10).pow(8) //1$
    let _maxSubmissionValue = BigNumber.from(10).pow(8).mul(10000) //10000$
    let _description = "ETHPrice"

    const PriceFeedOracle = await ethers.getContractFactory('PriceFeedOracle');
    const PriceFeedOracleInstance = await PriceFeedOracle.deploy(
        dtoTokenAddress, paymentAmount, deviationChecker.address, 
        _minSubmissionValue, _maxSubmissionValue, _description)
    const priceFeedOracle = await PriceFeedOracleInstance.deployed()
    log('  - PriceFeedOracle:         ', priceFeedOracle.address);

    deployData['PriceFeedOracle' + _description] = {
      abi: getContractAbi('PriceFeedOracle'),
      address: priceFeedOracle.address,
      deployTransaction: priceFeedOracle.deployTransaction,
    }

    saveDeploymentData(chainId, deployData);
    log('\n  Contract Deployment Data saved to "deployments" directory.');

    log('\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n');
};

module.exports.tags = ['protocol']
