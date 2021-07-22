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
  log('DTO Multichain Oracle Protocol - Multi Price Feed Contract Deployment');
  log('~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n');
  log('  dtoToken: ', dtoToken);

  log('  Using Network: ', chainNameById(chainId));
  log('  Using Accounts:');
  log('  - Deployer:          ', deployer);
  log('  - network id:          ', chainId);
  log('  - Owner:             ', protocolOwner);
  log('  - Trusted Forwarder: ', trustedForwarder);
  log(' ');

  log('  Deploying MultiPriceFeedOracle...');
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

  let deviationCheckerAddress = require(`../deployments/${chainId}/DeviationChecker.json`).address

  let tokenList = ["btc", "eth", "bnb", "ada", "etc", "xrp", "doge", "dot", "uni", "sol", "bch", "ltc", "link", "matic"]
  if (chainId == 31337) {
    tokenList = ["btc", "eth"]
  }
  let _description = tokenList.join("-")
  console.log('_description', _description)

  const MultiPriceFeedOracle = await ethers.getContractFactory('MultiPriceFeedOracle');
  const MultiPriceFeedOracleInstance = await MultiPriceFeedOracle.deploy(
    dtoTokenAddress, paymentAmount, deviationCheckerAddress)
  const multiPriceFeedOracle = await MultiPriceFeedOracleInstance.deployed()
  await multiPriceFeedOracle.initializeTokenList(_description, tokenList)
  log('  - MultiPriceFeedOracle:         ', multiPriceFeedOracle.address);
  console.log('oracles', oracles)

  if (chainId != 31337) {
    const ERC20Mock = await ethers.getContractFactory('ERC20Mock')
    const tokenContract = await ERC20Mock.attach(dtoTokenAddress)
    await tokenContract.transfer(multiPriceFeedOracle.address, BigNumber.from(10).pow(18).mul(10000))
    await multiPriceFeedOracle.changeOracles(
      [],
      oracles,
      oracles,
      6,
      10,
      { gasLimit: 10000000 }
    )
  }

  deployData['MultiPriceFeedOracle' + _description] = {
    abi: getContractAbi('MultiPriceFeedOracle'),
    address: multiPriceFeedOracle.address,
    deployTransaction: multiPriceFeedOracle.deployTransaction,
  }

  saveDeploymentData(chainId, deployData);
  log('\n  Contract Deployment Data saved to "deployments" directory.');

  log('\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n');
};

module.exports.tags = ['multipricefeed']
