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

const oraclesToAdd = [
  "0x3cdC0b9A2383770C24ce335C07DdD5f09EE3E199",
  "0x6D378C3dc2Eb8D433C3dDD6a62A6D41D44c18426",
  "0xC91B38d5Bf1d2047529446cF575855e0744e9334",
  "0x99F3dF513d1A13316CEA132B1431223d9612caEd",
  "0x6A61A3cEd260433ddD6F8E181644d55753A5051d",
  "0x58D337a11F1F439839bd2b97E0eE8e6D753be5d7",
  "0x9c76F50A0fFD21525b1E6406e306b628F492c4be",
  "0x6A96EaCff97c98c1D449D4E3634805241d85807f",
  "0x0cCacdd7c2F6bEbE61E80E77b24e5DE4d3B4C68B",
  "0xbE3ab443e16fdF70DfB35C73b45962CB56F9d9A6"
]

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
  log('  dtoToken: ', dtoToken);

  log('  Using Network: ', chainNameById(chainId));
  log('  Using Accounts:');
  log('  - Deployer:          ', deployer);
  log('  - network id:          ', chainId);
  log('  - Owner:             ', protocolOwner);
  log('  - Trusted Forwarder: ', trustedForwarder);
  log(' ');

  log('  Deploying PriceFeedOracle...');
  let dtoTokenAddress
  let oracles = []
  if (chainId == 31337) {
    dtoTokenAddress = require(`../deployments/${chainId}/DTOToken.json`).address
  } else {
    dtoTokenAddress = require(`../deployments/${chainId}/DTOToken.json`).address
    oracles.push(...oraclesToAdd)
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
  console.log('oracles', oracles)

  if (chainId != 31337) {
    const ERC20Mock = await ethers.getContractFactory('ERC20Mock')
    const tokenContract = await ERC20Mock.attach(dtoTokenAddress)
    await tokenContract.transfer(priceFeedOracle.address, BigNumber.from(10).pow(18).mul(10000))
    await priceFeedOracle.changeOracles(
      [],
      oracles,
      oracles,
      6,
      10,
      { gasLimit: 10000000 }
    )
  }


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
