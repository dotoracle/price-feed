// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "../lib/math/Median.sol";
import "../lib/math/SafeMath128.sol";
import "../lib/math/SafeMath32.sol";
import "../lib/math/SafeMath64.sol";
import "../interfaces/IMultiPriceFeed.sol";
import "./OracleFundManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";
import "./OraclePaymentManager.sol";
import "./PFConfig.sol";
import "../lib/access/EOACheck.sol";
import "../lib/access/SRAC.sol";

/**
 * @title The Prepaid Oracle contract
 * @notice Handles aggregating data pushed in from off-chain, and unlocks
 * payment for oracles as they report. Oracles' submissions are gathered in
 * rounds, with each round aggregating the submissions for each oracle into a
 * single answer. The latest aggregated answer is exposed as well as historical
 * answers and their updated at timestamp.
 */
contract MultiPriceFeedOracleV2 is
    IMultiPriceFeed,
    OraclePaymentManager,
    SRAC,
    Initializable
{
    using SafeMath for uint256;
    using SafeMath128 for uint128;
    using SafeMath64 for uint64;
    using SafeMath32 for uint32;
    using SafeERC20 for IERC20;
    using EOACheck for address;

    struct Round {
        int256[] answers;
        uint64 updatedAt; //timestamp
        uint128 paymentAmount;
    }

    struct SubmitterRewardsVesting {
        uint64 lastUpdated;
        uint128 releasable;
        uint128 remainVesting;
    }

    address public oracleDataValidator; //generated through MPC key gen

    string[] public tokenList;
    string public override description;

    uint256 public constant override version = 1;
    uint256 public constant MIN_THRESHOLD_PERCENT = 66;
    uint128 public percentX10SubmitterRewards = 5; //0.5%
    uint256 public constant SUBMITTER_REWARD_VESTING_PERIOD = 30 days;
    mapping(address => SubmitterRewardsVesting) public submitterRewards;

    mapping(uint32 => Round) internal rounds;

    event OraclePaymentV2(uint32 roundId, uint128 payment);
    /**
     * @notice set up the aggregator with initial configuration
     * @param _dto The address of the DTO token
     * @param _paymentAmount The amount paid of DTO paid to each oracle per submission, in wei (units of 10⁻¹⁸ DTO)
     * @param _validator is an optional contract address for validating
     * external validation of answers
     */
    constructor(
        address _dto,
        uint128 _paymentAmount,
        address _validator
    ) public OraclePaymentManager(_dto, _paymentAmount) {
        setChecker(_validator);
        rounds[0].updatedAt = uint64(block.timestamp);
    }

    function initializeTokenList(
        string memory _description,
        string[] memory _tokenList
    ) external initializer {
        description = _description;
        tokenList = _tokenList;
    }

    /*
     * ----------------------------------------ORACLE FUNCTIONS------------------------------------------------
     */

    /**
     * @notice V1, testnet, use simple ECDSA signatures combined in a single transaction
     * @notice called by oracles when they have witnessed a need to update, V1 uses ECDSA, V2 will use threshold shnorr singnature
     * @param _roundId is the ID of the round this submission pertains to
     * @param _prices are the updated data that the oracles are submitting
     * @param _deadline time at which the price is still valid. this time is determined by the oracles
     * @param r are the r signature data that the oracles are submitting
     * @param s are the s signature data that the oracles are submitting
     * @param v are the v signature data that the oracles are submitting
     */
    function submit(
        uint32 _roundId,
        int256[] memory _prices, //median prices of all tokens, median prices are calculated by the decentralized oracle network off-chain
        uint256 _deadline,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) external {
        require(
            _deadline >= block.timestamp,
            "PriceFeedOracle::submit deadline over"
        );

        require(
            _prices.length == tokenList.length,
            "PriceFeedOracle::submit Invalid submitted token count"
        );

        require(
            _roundId == lastReportedRound.add(1),
            "PriceFeedOracle::submit Invalid RoundId"
        );
        lastReportedRound = _roundId;
        Round storage currentRoundData = rounds[_roundId];

        currentRoundData.updatedAt = uint64(block.timestamp);

        bytes32 message = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encode(
                        _roundId,
                        address(this),
                        _prices,
                        _deadline,
                        tokenList,
                        description
                    )
                )
            )
        );
        address signer = ecrecover(message, v, r, s);
        require(signer == oracleDataValidator, "PriceFeedOracle::submit invalid oracle validator signature");

        payOracles(_roundId);
        emit AvailableFundsUpdated(recordedFunds.available);

        currentRoundData.answers = _prices;
        currentRoundData.paymentAmount = paymentAmount;

        emit AnswerUpdated(
            _roundId,
            abi.encodePacked(_prices),
            block.timestamp
        );

        validateRoundPrice(uint32(_roundId), _prices);

        //pay submitter rewards for incentivizations
        uint128 submitterRewardsToAppend = uint128(
            uint128(oracleCount())
            .mul(paymentAmount)
            .mul(percentX10SubmitterRewards)
            .div(1000)
        );

        appendSubmitterRewards(msg.sender, submitterRewardsToAppend);
    }

    function appendSubmitterRewards(address _submitter, uint128 _rewardsToAdd)
        internal
    {
        _updateSubmitterWithdrawnableRewards(_submitter);
        submitterRewards[_submitter].remainVesting = submitterRewards[
            _submitter
        ]
        .remainVesting
        .add(_rewardsToAdd);
    }

    function _updateSubmitterWithdrawnableRewards(address _submitter) internal {
        SubmitterRewardsVesting storage vestingInfo = submitterRewards[
            _submitter
        ];
        if (vestingInfo.remainVesting > 0) {
            uint128 unlockable = uint128(
                (block.timestamp.sub(vestingInfo.lastUpdated))
                .mul(vestingInfo.remainVesting)
                .div(SUBMITTER_REWARD_VESTING_PERIOD)
            );
            if (unlockable > vestingInfo.remainVesting) {
                unlockable = vestingInfo.remainVesting;
            }
            vestingInfo.remainVesting = vestingInfo.remainVesting.sub(
                unlockable
            );
            vestingInfo.releasable = vestingInfo.releasable.add(unlockable);
        }
        vestingInfo.lastUpdated = uint64(block.timestamp);
    }

    function unlockSubmitterRewards(address _submitter) external {
        _updateSubmitterWithdrawnableRewards(_submitter);
        if (submitterRewards[_submitter].releasable > 0) {
            dtoToken.safeTransfer(
                _submitter,
                submitterRewards[_submitter].releasable
            );
            recordedFunds.allocated = recordedFunds.allocated.sub(
                submitterRewards[_submitter].releasable
            );
            submitterRewards[_submitter].releasable = 0;
        }
    }

    function addFunds(uint256 _amount) external {
        dtoToken.safeTransferFrom(msg.sender, address(this), _amount);
        updateAvailableFunds();
    }

    function validateRoundPrice(uint32 _roundId, int256[] memory _newAnswers)
        private
    {
        IDataChecker av = checker; // cache storage reads
        if (address(av) == address(0)) return;
        if (_roundId == 1) return; //dont need to validate first round
        uint32 prevRound = _roundId.sub(1);
        Round storage previousRound = rounds[prevRound];
        for (uint256 i = 0; i < _newAnswers.length; i++) {
            int256 prevRoundAnswer = previousRound.answers[i];
            // We do not want the validator to ever prevent reporting, so we limit its
            // gas usage and catch any errors that may arise.
            try
                av.validate{gas: VALIDATOR_GAS_LIMIT}(
                    prevRound,
                    prevRoundAnswer,
                    _roundId,
                    _newAnswers[i]
                )
            {} catch {}
        }
    }

    function payOracles(uint32 _roundId) private {
        uint128 payment = paymentAmount;
        Funds memory funds = recordedFunds;
        funds.available = funds.available.sub(payment.mul(oracleCount()));
        funds.allocated = funds.allocated.add(payment.mul(oracleCount()));
        recordedFunds = funds;
        for(uint i = 0; i < oracleCount(); i++) {
            address _oracle = oracleAddresses[i];
            oracles[_oracle].withdrawable = oracles[_oracle].withdrawable.add(
                payment.mul(uint128(1000) - percentX10SubmitterRewards).div(1000)
            );
        }
        emit OraclePaymentV2(_roundId, payment);
    }

    function changeOracleValidator(address _newValidator) external onlyOwner {
        oracleDataValidator = _newValidator;
    }

    /*
     * ----------------------------------------VIEW FUNCTIONS------------------------------------------------
     */
    function latestAnswer()
        public
        view
        virtual
        override
        checkAccess
        returns (int256[] memory)
    {
        return rounds[lastReportedRound].answers;
    }

    function latestAnswerOfToken(uint32 _tokenIndex)
        external
        view
        override
        checkAccess
        returns (int256)
    {
        return rounds[lastReportedRound].answers[_tokenIndex];
    }

    function latestUpdated() public view virtual override returns (uint256) {
        return rounds[lastReportedRound].updatedAt;
    }

    function latestRound() public view virtual override returns (uint256) {
        return lastReportedRound;
    }

    function getAnswerByRound(uint256 _roundId)
        public
        view
        virtual
        override
        checkAccess
        returns (int256[] memory)
    {
        if (validRoundId(_roundId)) {
            return rounds[uint32(_roundId)].answers;
        }
        return new int256[](0);
    }

    function getAnswerByRoundOfToken(uint32 _tokenIndex, uint256 _roundId)
        external
        view
        override
        checkAccess
        returns (int256)
    {
        return rounds[uint32(_roundId)].answers[_tokenIndex];
    }

    function getUpdatedTime(uint256 _roundId)
        public
        view
        virtual
        override
        returns (uint256)
    {
        if (validRoundId(_roundId)) {
            return rounds[uint32(_roundId)].updatedAt;
        }
        return 0;
    }

    function getRoundInfo(uint80 _roundId)
        public
        view
        virtual
        override
        checkAccess
        returns (
            uint80 roundId,
            int256[] memory answers,
            uint256 updatedAt
        )
    {
        Round memory r = rounds[uint32(_roundId)];

        require(validRoundId(_roundId), V3_NO_DATA_ERROR);

        return (_roundId, r.answers, r.updatedAt);
    }

    function getRoundInfoOfToken(uint32 _tokenIndex, uint80 _roundId)
        external
        view
        override
        checkAccess
        returns (
            uint80 roundId,
            int256 answer,
            uint256 updatedAt
        )
    {
        Round memory r = rounds[uint32(_roundId)];

        require(validRoundId(_roundId), V3_NO_DATA_ERROR);

        return (_roundId, r.answers[_tokenIndex], r.updatedAt);
    }

    function latestRoundInfo()
        public
        view
        virtual
        override
        checkAccess
        returns (
            uint80 roundId,
            int256[] memory answers,
            uint256 updatedAt
        )
    {
        return getRoundInfo(lastReportedRound);
    }

    function latestRoundInfoOfToken(uint32 _tokenIndex)
        external
        view
        override
        checkAccess
        returns (
            uint80 roundId,
            int256 answer,
            uint256 updatedAt
        )
    {
        Round memory r = rounds[uint32(lastReportedRound)];

        require(validRoundId(lastReportedRound), V3_NO_DATA_ERROR);

        return (lastReportedRound, r.answers[_tokenIndex], r.updatedAt);
    }

    /**
     * @notice get the admin address of an oracle
     * @param _oracle is the address of the oracle whose admin is being queried
     */
    function getAdmin(address _oracle) external view returns (address) {
        return oracles[_oracle].admin;
    }

    /**
     * @notice a method to provide all current info oracles need. Intended only
     * only to be callable by oracles. Not for use by contracts to read state.
     * @param _oracle the address to look up information for.
     */
    function oracleRoundState(address _oracle, uint32 _queriedRoundId)
        external
        view
        checkAccess
        returns (
            bool _eligibleToSubmit,
            uint32 _roundId,
            uint128 _availableFunds,
            uint8 _oracleCount,
            uint128 _paymentAmount
        )
    {
        require(
            address(msg.sender).isCalledFromEOA(),
            "off-chain reading only"
        );
        require(_queriedRoundId > 0, "_queriedRoundId > 0");

        Round storage round = rounds[_queriedRoundId];
        return (
            eligibleForSpecificRound(_oracle, _queriedRoundId),
            _queriedRoundId,
            recordedFunds.available,
            oracleCount(),
            (round.updatedAt > 0 ? round.paymentAmount : paymentAmount)
        );
    }

    function eligibleForSpecificRound(address _oracle, uint32 _queriedRoundId)
        private
        view
        returns (bool _eligible)
    {
        return oracles[_oracle].endingRound >= _queriedRoundId;
    }

    function validRoundId(uint256 _roundId) private pure returns (bool) {
        return _roundId <= ROUND_MAX;
    }

    function getTokenList() external view returns (string[] memory) {
        return tokenList;
    }
}
