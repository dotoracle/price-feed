// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "../lib/math/Median.sol";
import "../lib/math/SafeMath128.sol";
import "../lib/math/SafeMath32.sol";
import "../lib/math/SafeMath64.sol";
import "../interfaces/IPriceFeed.sol";
import "./OracleFundManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./PriceChecker.sol";
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
contract PriceFeedOracle is
    IPriceFeed,
    PriceChecker,
    OracleFundManager,
    PFConfig,
    SRAC
{
    using SafeMath for uint256;
    using SafeMath128 for uint128;
    using SafeMath64 for uint64;
    using SafeMath32 for uint32;
    using SafeERC20 for IERC20;
    using EOACheck for address;

    struct Round {
        int256 answer;
        uint64 updatedAt; //timestamp
        uint32 answeredInRound;
        int256[] submissions;
        address[] oracles;
        uint128 paymentAmount;
    }

    struct SubmitterRewardsVesting {
        uint64 lastUpdated;
        uint128 releasable;
        uint128 remainVesting;
    }

    // Round related params
    uint32 public maxSubmissionCount;
    uint32 public minSubmissionCount;
    string public override description;

    uint256 public constant override version = 1;
    uint256 public constant MIN_THRESHOLD_PERCENT = 66;
    uint128 public percentX10SubmitterRewards = 5; //0.5%
    uint256 public constant SUBMITTER_REWARD_VESTING_PERIOD = 30 days;
    mapping(address => SubmitterRewardsVesting) public submitterRewards;

    uint32 internal lastReportedRound;
    mapping(uint32 => Round) internal rounds;

    event RoundSettingsUpdated(
        uint128 indexed paymentAmount,
        uint32 indexed minSubmissionCount,
        uint32 indexed maxSubmissionCount
    );

    event SubmissionReceived(int256 price, uint32 indexed round);

    /**
     * @notice set up the aggregator with initial configuration
     * @param _dto The address of the DTO token
     * @param _paymentAmount The amount paid of DTO paid to each oracle per submission, in wei (units of 10⁻¹⁸ DTO)
     * @param _validator is an optional contract address for validating
     * external validation of answers
     * @param _minSubmissionValue is an immutable check for a lower bound of what
     * submission values are accepted from an oracle
     * @param _maxSubmissionValue is an immutable check for an upper bound of what
     * submission values are accepted from an oracle
     * @param _description a short description of what is being reported
     */
    constructor(
        address _dto,
        uint128 _paymentAmount,
        address _validator,
        int256 _minSubmissionValue,
        int256 _maxSubmissionValue,
        string memory _description
    ) public PFConfig(_minSubmissionValue, _maxSubmissionValue) {
        dtoToken = IERC20(_dto);
        updateFutureRounds(_paymentAmount, 0, 0);
        setChecker(_validator);
        description = _description;
        rounds[0].updatedAt = uint64(block.timestamp);
    }

    /*
     * ----------------------------------------ADMIN FUNCTIONS------------------------------------------------
     */

    /**
     * @notice called by the owner to remove and add new oracles as well as
     * update the round related parameters that pertain to total oracle count
     * @param _removed is the list of addresses for the new Oracles being removed
     * @param _added is the list of addresses for the new Oracles being added
     * @param _addedAdmins is the admin addresses for the new respective _added
     * list. Only this address is allowed to access the respective oracle's funds
     * @param _minSubmissions is the new minimum submission count for each round
     * @param _maxSubmissions is the new maximum submission count for each round
     */
    function changeOracles(
        address[] calldata _removed,
        address[] calldata _added,
        address[] calldata _addedAdmins,
        uint32 _minSubmissions,
        uint32 _maxSubmissions
    ) external onlyOwner() {
        updateAvailableFunds();
        for (uint256 i = 0; i < _removed.length; i++) {
            removeOracle(_removed[i]);
        }

        require(
            _added.length == _addedAdmins.length,
            "PriceFeedOracle::changeOracles need same oracle and admin count"
        );
        require(
            uint256(oracleCount()).add(_added.length) <= MAX_ORACLE_COUNT,
            "PriceFeedOracle::changeOracles max oracles allowed"
        );

        for (uint256 i = 0; i < _added.length; i++) {
            addOracle(_added[i], _addedAdmins[i]);
        }

        updateFutureRounds(paymentAmount, _minSubmissions, _maxSubmissions);
    }

    function addOracle(address _oracle, address _admin) internal {
        require(!isOracleEnabled(_oracle), "oracle already enabled");

        require(_admin != address(0), "cannot set admin to 0");
        require(
            oracles[_oracle].admin == address(0) ||
                oracles[_oracle].admin == _admin,
            "owner cannot overwrite admin"
        );

        oracles[_oracle].startingRound = getStartingRound(_oracle);
        oracles[_oracle].endingRound = ROUND_MAX;
        oracles[_oracle].index = uint16(oracleAddresses.length);
        oracleAddresses.push(_oracle);
        oracles[_oracle].admin = _admin;

        emit OraclePermissionsUpdated(_oracle, true);
        emit OracleAdminUpdated(_oracle, _admin);
    }

    function removeOracle(address _oracle) internal {
        require(isOracleEnabled(_oracle), "oracle not enabled");

        oracles[_oracle].endingRound = lastReportedRound.add(1);
        address tail = oracleAddresses[uint256(oracleCount()).sub(1)];
        uint16 index = oracles[_oracle].index;
        oracles[tail].index = index;
        delete oracles[_oracle].index;
        oracleAddresses[index] = tail;
        oracleAddresses.pop();

        emit OraclePermissionsUpdated(_oracle, false);
    }

    /**
     * @notice update the round and payment related parameters for subsequent
     * rounds
     * @param _paymentAmount is the payment amount for subsequent rounds
     * @param _minSubmissions is the new minimum submission count for each round
     * @param _maxSubmissions is the new maximum submission count for each round
     */
    function updateFutureRounds(
        uint128 _paymentAmount,
        uint32 _minSubmissions,
        uint32 _maxSubmissions
    ) public onlyOwner() {
        uint32 oracleNum = oracleCount(); // Save on storage reads
        require(
            _maxSubmissions >= _minSubmissions,
            "max must equal/exceed min"
        );
        require(oracleNum >= _maxSubmissions, "max cannot exceed total");
        require(
            recordedFunds.available >= computeRequiredReserve(_paymentAmount),
            "PriceFeedOracle::updateFutureRounds insufficient funds for payment"
        );
        if (oracleCount() > 0) {
            require(_minSubmissions > 0, "min must be greater than 0");
        }

        paymentAmount = _paymentAmount;
        minSubmissionCount = _minSubmissions;
        maxSubmissionCount = _maxSubmissions;

        emit RoundSettingsUpdated(
            paymentAmount,
            _minSubmissions,
            _maxSubmissions
        );
    }

    /**
     * @notice transfer the admin address for an oracle
     * @param _oracle is the address of the oracle whose admin is being transferred
     * @param _newAdmin is the new admin address
     */
    function transferAdmin(address _oracle, address _newAdmin) external {
        require(oracles[_oracle].admin == msg.sender, "only callable by admin");
        oracles[_oracle].pendingAdmin = _newAdmin;

        emit OracleAdminUpdateRequested(_oracle, msg.sender, _newAdmin);
    }

    /**
     * @notice accept the admin address transfer for an oracle
     * @param _oracle is the address of the oracle whose admin is being transferred
     */
    function acceptAdmin(address _oracle) external {
        require(
            oracles[_oracle].pendingAdmin == msg.sender,
            "only callable by pending admin"
        );
        oracles[_oracle].pendingAdmin = address(0);
        oracles[_oracle].admin = msg.sender;

        emit OracleAdminUpdated(_oracle, msg.sender);
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
        int256[] memory _prices,
        uint256 _deadline,
        bytes32[] memory r,
        bytes32[] memory s,
        uint8[] memory v
    ) external {
        updateAvailableFunds();
        require(
            _deadline >= block.timestamp,
            "PriceFeedOracle::submit deadline over"
        );
        require(
            _prices.length == r.length &&
                r.length == s.length &&
                s.length == v.length,
            "PriceFeedOracle::submit Invalid input paramters length"
        );
        require(
            v.length.mul(100).div(oracleAddresses.length) >=
                MIN_THRESHOLD_PERCENT,
            "PriceFeedOracle::submit Number of submissions under threshold"
        );

        require(
            _prices.length >= minSubmissionCount,
            "PriceFeedOracle::submit submissions under min submission count"
        );

        require(
            _roundId == lastReportedRound.add(1),
            "PriceFeedOracle::submit Invalid RoundId"
        );
        createNewRound(_roundId);
        Round storage currentRoundData = rounds[_roundId];

        bytes32 message = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encode(_roundId, address(this), _prices, _deadline, description)
                )
            )
        );
        for (uint256 i = 0; i < _prices.length; i++) {
            //TODO: value range can be checked off-chain to further optimize gas
            require(
                _prices[i] >= minSubmissionValue,
                "value below minSubmissionValue"
            );
            require(
                _prices[i] <= maxSubmissionValue,
                "value above maxSubmissionValue"
            );

            address signer = ecrecover(
                message,
                v[i],
                r[i],
                s[i]
            );
            //the off-chain network dotoracle must verify there is no duplicate oracles in the submissions
            require(
                isOracleEnabled(signer),
                "PriceFeedOracle::submit submissions data corrupted or invalid"
            );
            currentRoundData.oracles.push(signer);
            payOracle(signer);
        }

        (bool updated, int256 newAnswer) = updateRoundPrice(
            uint32(_roundId),
            _prices
        );
        if (updated) {
            validateRoundPrice(uint32(_roundId), newAnswer);
            emit SubmissionReceived(newAnswer, uint32(_roundId));
        }

        //pay submitter rewards for incentivizations
        uint128 submitterRewardsToAppend = uint128(
            _prices
            .length
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

    /**
     * Private
     */

    function createNewRound(uint32 _roundId) private {
        updateRoundInfo(_roundId);

        lastReportedRound = _roundId;
        rounds[_roundId].updatedAt = uint64(block.timestamp);

        emit NewRound(_roundId, msg.sender, rounds[_roundId].updatedAt);
    }

    function validateRoundPrice(uint32 _roundId, int256 _newAnswer) private {
        IDataChecker av = checker; // cache storage reads
        if (address(av) == address(0)) return;

        uint32 prevRound = _roundId.sub(1);
        uint32 prevAnswerRoundId = rounds[prevRound].answeredInRound;
        int256 prevRoundAnswer = rounds[prevRound].answer;
        // We do not want the validator to ever prevent reporting, so we limit its
        // gas usage and catch any errors that may arise.
        try
            av.validate{gas: VALIDATOR_GAS_LIMIT}(
                prevAnswerRoundId,
                prevRoundAnswer,
                _roundId,
                _newAnswer
            )
        {} catch {}
    }

    function updateRoundInfo(uint32 _roundId) private {
        uint32 prevId = _roundId.sub(1);
        rounds[_roundId].answer = rounds[prevId].answer;
        rounds[_roundId].answeredInRound = rounds[prevId].answeredInRound;
        rounds[_roundId].updatedAt = uint64(block.timestamp);
    }

    function updateRoundPrice(uint32 _roundId, int256[] memory _prices)
        internal
        returns (bool, int256)
    {
        int256 newAnswer = Median.calculateInplace(_prices);
        rounds[_roundId].answer = newAnswer;
        rounds[_roundId].updatedAt = uint64(block.timestamp);
        rounds[_roundId].answeredInRound = _roundId;

        emit AnswerUpdated(newAnswer, _roundId, block.timestamp);

        return (true, newAnswer);
    }

    function payOracle(address _oracle) private {
        uint128 payment = paymentAmount;
        Funds memory funds = recordedFunds;
        funds.available = funds.available.sub(payment);
        funds.allocated = funds.allocated.add(payment);
        recordedFunds = funds;
        oracles[_oracle].withdrawable = oracles[_oracle].withdrawable.add(
            payment.mul(uint128(1000) - percentX10SubmitterRewards).div(1000)
        );

        emit AvailableFundsUpdated(funds.available);
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
        returns (int256)
    {
        return rounds[lastReportedRound].answer;
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
        returns (int256)
    {
        if (validRoundId(_roundId)) {
            return rounds[uint32(_roundId)].answer;
        }
        return 0;
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
            int256 answer,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        Round memory r = rounds[uint32(_roundId)];

        require(
            r.answeredInRound > 0 && validRoundId(_roundId),
            V3_NO_DATA_ERROR
        );

        return (_roundId, r.answer, r.updatedAt, r.answeredInRound);
    }

    function latestRoundInfo()
        public
        view
        virtual
        override
        checkAccess
        returns (
            uint80 roundId,
            int256 answer,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return getRoundInfo(lastReportedRound);
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

    function getStartingRound(address _oracle) private view returns (uint32) {
        uint32 currentRound = lastReportedRound;
        if (currentRound != 0 && currentRound == oracles[_oracle].endingRound) {
            return currentRound;
        }
        return currentRound.add(1);
    }

    function validRoundId(uint256 _roundId) private pure returns (bool) {
        return _roundId <= ROUND_MAX;
    }

    function isOracleEnabled(address _oracle) internal view returns (bool) {
        return oracles[_oracle].endingRound == ROUND_MAX;
    }

    function computeRequiredReserve(uint256 payment)
        internal
        view
        override
        returns (uint256)
    {
        return payment.mul(oracleCount()).mul(RESERVE_ROUNDS);
    }
}
