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
import "./DataChecker.sol";
import "./PFConfig.sol";
import "../lib/access/EOACheck.sol";

/**
 * @title The Prepaid Oracle contract
 * @notice Handles aggregating data pushed in from off-chain, and unlocks
 * payment for oracles as they report. Oracles' submissions are gathered in
 * rounds, with each round aggregating the submissions for each oracle into a
 * single answer. The latest aggregated answer is exposed as well as historical
 * answers and their updated at timestamp.
 */
contract PriceFeed is
    IPriceFeed,
    DataChecker,
    OracleFundManager,
    PFConfig
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
        uint64 startedAt;
        uint32 answeredInRound;
    }

    struct RoundDetails {
        int256[] submissions;
        uint32 maxSubmissions;
        uint32 minSubmissions;
        uint32 timeout;
        uint128 paymentAmount;
        address[] submitters;
    }

    struct Requester {
        bool authorized;
        uint32 delay;
        uint32 lastStartedRound;
    }

    // Round related params
    uint32 public maxSubmissionCount;
    uint32 public minSubmissionCount;
    uint32 public restartDelay;
    uint32 public timeout;
    uint8 public override decimals;
    string public override description;

    uint256 constant override public version = 3;

    uint32 private reportingRoundId;
    uint32 internal latestRoundId;
    mapping(uint32 => Round) internal rounds;
    mapping(uint32 => RoundDetails) internal details;
    mapping(address => Requester) internal requesters;

    event RoundDetailsUpdated(
        uint128 indexed paymentAmount,
        uint32 indexed minSubmissionCount,
        uint32 indexed maxSubmissionCount,
        uint32 restartDelay,
        uint32 timeout // measured in seconds
    );

    event SubmissionReceived(
        int256 indexed submission,
        uint32 indexed round,
        address indexed oracle
    );
    event RequesterPermissionsSet(
        address indexed requester,
        bool authorized,
        uint32 delay
    );

    /**
     * @notice set up the aggregator with initial configuration
     * @param _dto The address of the DTO token
     * @param _paymentAmount The amount paid of DTO paid to each oracle per submission, in wei (units of 10⁻¹⁸ DTO)
     * @param _timeout is the number of seconds after the previous round that are
     * allowed to lapse before allowing an oracle to skip an unfinished round
     * @param _validator is an optional contract address for validating
     * external validation of answers
     * @param _minSubmissionValue is an immutable check for a lower bound of what
     * submission values are accepted from an oracle
     * @param _maxSubmissionValue is an immutable check for an upper bound of what
     * submission values are accepted from an oracle
     * @param _decimals represents the number of decimals to offset the answer by
     * @param _description a short description of what is being reported
     */
    constructor(
        address _dto,
        uint128 _paymentAmount,
        uint32 _timeout,
        address _validator,
        int256 _minSubmissionValue,
        int256 _maxSubmissionValue,
        uint8 _decimals,
        string memory _description
    ) public PFConfig(_minSubmissionValue, _maxSubmissionValue) {
        dtoToken = IERC20(_dto);
        updateFutureRounds(_paymentAmount, 0, 0, 0, _timeout);
        setChecker(_validator);
        decimals = _decimals;
        description = _description;
        rounds[0].updatedAt = uint64(block.timestamp.sub(uint256(_timeout)));
    }

    /**
     * @notice called by oracles when they have witnessed a need to update
     * @param _roundId is the ID of the round this submission pertains to
     * @param _submissions are the updated data that the oracles are submitting
     */
    function submit(
        uint256 _roundId,
        int256[] memory _submissions,
        bytes32[] memory r,
        bytes32[] memory v,
        uint8[] memory s
    ) external {
        // bytes memory error = validateOracleRound(msg.sender, uint32(_roundId));
        // require(
        //     _submission >= minSubmissionValue,
        //     "value below minSubmissionValue"
        // );
        // require(
        //     _submission <= maxSubmissionValue,
        //     "value above maxSubmissionValue"
        // );
        // require(error.length == 0, string(error));

        // oracleInitializeNewRound(uint32(_roundId));
        // recordSubmission(_submission, uint32(_roundId));
        // (bool updated, int256 newAnswer) = updateRoundAnswer(uint32(_roundId));
        // payOracle(uint32(_roundId));
        // deleteRoundDetails(uint32(_roundId));
        // if (updated) {
        //     validateAnswer(uint32(_roundId), newAnswer);
        // }
    }

    /**
     * @notice called by the owner to remove and add new oracles as well as
     * update the round related parameters that pertain to total oracle count
     * @param _removed is the list of addresses for the new Oracles being removed
     * @param _added is the list of addresses for the new Oracles being added
     * @param _addedAdmins is the admin addresses for the new respective _added
     * list. Only this address is allowed to access the respective oracle's funds
     * @param _minSubmissions is the new minimum submission count for each round
     * @param _maxSubmissions is the new maximum submission count for each round
     * @param _restartDelay is the number of rounds an Oracle has to wait before
     * they can initiate a round
     */
    function changeOracles(
        address[] calldata _removed,
        address[] calldata _added,
        address[] calldata _addedAdmins,
        uint32 _minSubmissions,
        uint32 _maxSubmissions,
        uint32 _restartDelay
    ) external onlyOwner() {
        for (uint256 i = 0; i < _removed.length; i++) {
            removeOracle(_removed[i]);
        }

        require(
            _added.length == _addedAdmins.length,
            "need same oracle and admin count"
        );
        require(
            uint256(oracleCount()).add(_added.length) <= MAX_ORACLE_COUNT,
            "max oracles allowed"
        );

        for (uint256 i = 0; i < _added.length; i++) {
            addOracle(_added[i], _addedAdmins[i]);
        }

        updateFutureRounds(
            paymentAmount,
            _minSubmissions,
            _maxSubmissions,
            _restartDelay,
            timeout
        );
    }

    /**
     * @notice update the round and payment related parameters for subsequent
     * rounds
     * @param _paymentAmount is the payment amount for subsequent rounds
     * @param _minSubmissions is the new minimum submission count for each round
     * @param _maxSubmissions is the new maximum submission count for each round
     * @param _restartDelay is the number of rounds an Oracle has to wait before
     * they can initiate a round
     */
    function updateFutureRounds(
        uint128 _paymentAmount,
        uint32 _minSubmissions,
        uint32 _maxSubmissions,
        uint32 _restartDelay,
        uint32 _timeout
    ) public onlyOwner() {
        uint32 oracleNum = oracleCount(); // Save on storage reads
        require(
            _maxSubmissions >= _minSubmissions,
            "max must equal/exceed min"
        );
        require(oracleNum >= _maxSubmissions, "max cannot exceed total");
        require(
            oracleNum == 0 || oracleNum > _restartDelay,
            "delay cannot exceed total"
        );
        require(
            recordedFunds.available >= requiredReserve(_paymentAmount),
            "insufficient funds for payment"
        );
        if (oracleCount() > 0) {
            require(_minSubmissions > 0, "min must be greater than 0");
        }

        paymentAmount = _paymentAmount;
        minSubmissionCount = _minSubmissions;
        maxSubmissionCount = _maxSubmissions;
        restartDelay = _restartDelay;
        timeout = _timeout;

        emit RoundDetailsUpdated(
            paymentAmount,
            _minSubmissions,
            _maxSubmissions,
            _restartDelay,
            _timeout
        );
    }

    /**
     * @notice get the most recently reported answer
     *
     * @dev #[deprecated] Use latestRoundData instead. This does not error if no
     * answer has been reached, it will simply return 0. Either wait to point to
     * an already answered Aggregator or use the recommended latestRoundData
     * instead which includes better verification information.
     */
    function latestAnswer() public view virtual override returns (int256) {
        return rounds[latestRoundId].answer;
    }

    /**
     * @notice get the most recent updated at timestamp
     *
     * @dev #[deprecated] Use latestRoundData instead. This does not error if no
     * answer has been reached, it will simply return 0. Either wait to point to
     * an already answered Aggregator or use the recommended latestRoundData
     * instead which includes better verification information.
     */
    function latestTimestamp() public view virtual override returns (uint256) {
        return rounds[latestRoundId].updatedAt;
    }

    /**
     * @notice get the ID of the last updated round
     *
     * @dev #[deprecated] Use latestRoundData instead. This does not error if no
     * answer has been reached, it will simply return 0. Either wait to point to
     * an already answered Aggregator or use the recommended latestRoundData
     * instead which includes better verification information.
     */
    function latestRound() public view virtual override returns (uint256) {
        return latestRoundId;
    }

    /**
     * @notice get past rounds answers
     * @param _roundId the round number to retrieve the answer for
     *
     * @dev #[deprecated] Use getRoundData instead. This does not error if no
     * answer has been reached, it will simply return 0. Either wait to point to
     * an already answered Aggregator or use the recommended getRoundData
     * instead which includes better verification information.
     */
    function getAnswer(uint256 _roundId)
        public
        view
        virtual
        override
        returns (int256)
    {
        if (validRoundId(_roundId)) {
            return rounds[uint32(_roundId)].answer;
        }
        return 0;
    }

    /**
     * @notice get timestamp when an answer was last updated
     * @param _roundId the round number to retrieve the updated timestamp for
     *
     * @dev #[deprecated] Use getRoundData instead. This does not error if no
     * answer has been reached, it will simply return 0. Either wait to point to
     * an already answered Aggregator or use the recommended getRoundData
     * instead which includes better verification information.
     */
    function getTimestamp(uint256 _roundId)
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

    /**
     * @notice get data about a round. Consumers are encouraged to check
     * that they're receiving fresh data by inspecting the updatedAt and
     * answeredInRound return values.
     * @param _roundId the round ID to retrieve the round data for
     * @return roundId is the round ID for which data was retrieved
     * @return answer is the answer for the given round
     * @return startedAt is the timestamp when the round was started. This is 0
     * if the round hasn't been started yet.
     * @return updatedAt is the timestamp when the round last was updated (i.e.
     * answer was last computed)
     * @return answeredInRound is the round ID of the round in which the answer
     * was computed. answeredInRound may be smaller than roundId when the round
     * timed out. answeredInRound is equal to roundId when the round didn't time out
     * and was completed regularly.
     * @dev Note that for in-progress rounds (i.e. rounds that haven't yet received
     * maxSubmissions) answer and updatedAt may change between queries.
     */
    function getRoundData(uint80 _roundId)
        public
        view
        virtual
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        Round memory r = rounds[uint32(_roundId)];

        require(
            r.answeredInRound > 0 && validRoundId(_roundId),
            V3_NO_DATA_ERROR
        );

        return (
            _roundId,
            r.answer,
            r.startedAt,
            r.updatedAt,
            r.answeredInRound
        );
    }

    /**
     * @notice get data about the latest round. Consumers are encouraged to check
     * that they're receiving fresh data by inspecting the updatedAt and
     * answeredInRound return values. Consumers are encouraged to
     * use this more fully featured method over the "legacy" latestRound/
     * latestAnswer/latestTimestamp functions. Consumers are encouraged to check
     * that they're receiving fresh data by inspecting the updatedAt and
     * answeredInRound return values.
     * @return roundId is the round ID for which data was retrieved
     * @return answer is the answer for the given round
     * @return startedAt is the timestamp when the round was started. This is 0
     * if the round hasn't been started yet.
     * @return updatedAt is the timestamp when the round last was updated (i.e.
     * answer was last computed)
     * @return answeredInRound is the round ID of the round in which the answer
     * was computed. answeredInRound may be smaller than roundId when the round
     * timed out. answeredInRound is equal to roundId when the round didn't time
     * out and was completed regularly.
     * @dev Note that for in-progress rounds (i.e. rounds that haven't yet
     * received maxSubmissions) answer and updatedAt may change between queries.
     */
    function latestRoundData()
        public
        view
        virtual
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return getRoundData(latestRoundId);
    }

    /**
     * @notice get the admin address of an oracle
     * @param _oracle is the address of the oracle whose admin is being queried
     */
    function getAdmin(address _oracle) external view returns (address) {
        return oracles[_oracle].admin;
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

    /**
     * @notice allows non-oracles to request a new round
     */
    function requestNewRound(address[] memory submitters) external returns (uint80) {
        require(requesters[msg.sender].authorized, "not authorized requester");

        uint32 current = reportingRoundId;
        require(
            rounds[current].updatedAt > 0 || timedOut(current),
            "prev round must be supersedable"
        );

        uint32 newRoundId = current.add(1);
        requesterInitializeNewRound(newRoundId, submitters);
        return newRoundId;
    }

    /**
     * @notice allows the owner to specify new non-oracles to start new rounds
     * @param _requester is the address to set permissions for
     * @param _authorized is a boolean specifying whether they can start new rounds or not
     * @param _delay is the number of rounds the requester must wait before starting another round
     */
    function setRequesterPermissions(
        address _requester,
        bool _authorized,
        uint32 _delay
    ) external onlyOwner() {
        if (requesters[_requester].authorized == _authorized) return;

        if (_authorized) {
            requesters[_requester].authorized = _authorized;
            requesters[_requester].delay = _delay;
        } else {
            delete requesters[_requester];
        }

        emit RequesterPermissionsSet(_requester, _authorized, _delay);
    }

    /**
     * @notice called through DTO's transferAndCall to update available funds
     * in the same transaction as the funds were transferred to the aggregator
     * @param _data is mostly ignored. It is checked for length, to be sure
     * nothing strange is passed in.
     */
    function onTokenTransfer(
        address,
        uint256,
        bytes calldata _data
    ) external {
        require(_data.length == 0, "transfer doesn't accept calldata");
        updateAvailableFunds();
    }

    /**
     * @notice a method to provide all current info oracles need. Intended only
     * only to be callable by oracles. Not for use by contracts to read state.
     * @param _oracle the address to look up information for.
     */
    function oracleRoundState(address _oracle, uint32 _queriedRoundId)
        external
        view
        returns (
            bool _eligibleToSubmit,
            uint32 _roundId,
            int256 _latestSubmission,
            uint64 _startedAt,
            uint64 _timeout,
            uint128 _availableFunds,
            uint8 _oracleCount,
            uint128 _paymentAmount
        )
    {
        require(address(msg.sender).isCalledFromEOA(), "off-chain reading only");

        if (_queriedRoundId > 0) {
            Round storage round = rounds[_queriedRoundId];
            RoundDetails storage details = details[_queriedRoundId];
            return (
                eligibleForSpecificRound(_oracle, _queriedRoundId),
                _queriedRoundId,
                oracles[_oracle].latestSubmission,
                round.startedAt,
                details.timeout,
                recordedFunds.available,
                oracleCount(),
                (round.startedAt > 0 ? details.paymentAmount : paymentAmount)
            );
        } else {
            return oracleRoundStateSuggestRound(_oracle);
        }
    }

    /**
     * Private
     */

    function initializeNewRound(uint32 _roundId, address[] memory submitters) private {
        updateTimedOutRoundInfo(_roundId.sub(1));

        reportingRoundId = _roundId;
        RoundDetails memory nextDetails = RoundDetails(
            new int256[](0),
            maxSubmissionCount,
            minSubmissionCount,
            timeout,
            paymentAmount,
            submitters
        );
        details[_roundId] = nextDetails;
        rounds[_roundId].startedAt = uint64(block.timestamp);

        emit NewRound(_roundId, msg.sender, rounds[_roundId].startedAt);
    }

    function oracleInitializeNewRound(uint32 _roundId, address[] memory submitters) private {
        if (!newRound(_roundId)) return;
        uint256 lastStarted = oracles[msg.sender].lastStartedRound; // cache storage reads
        if (_roundId <= lastStarted + restartDelay && lastStarted != 0) return;

        initializeNewRound(_roundId, submitters);

        oracles[msg.sender].lastStartedRound = _roundId;
    }

    function validateAnswer(uint32 _roundId, int256 _newAnswer) private {
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

    function requesterInitializeNewRound(uint32 _roundId, address[] memory submitters) private {
        if (!newRound(_roundId)) return;
        uint256 lastStarted = requesters[msg.sender].lastStartedRound; // cache storage reads
        require(
            _roundId > lastStarted + requesters[msg.sender].delay ||
                lastStarted == 0,
            "must delay requests"
        );

        initializeNewRound(_roundId, submitters);

        requesters[msg.sender].lastStartedRound = _roundId;
    }

    function updateTimedOutRoundInfo(uint32 _roundId) private {
        if (!timedOut(_roundId)) return;

        uint32 prevId = _roundId.sub(1);
        rounds[_roundId].answer = rounds[prevId].answer;
        rounds[_roundId].answeredInRound = rounds[prevId].answeredInRound;
        rounds[_roundId].updatedAt = uint64(block.timestamp);

        delete details[_roundId];
    }

    function eligibleForSpecificRound(address _oracle, uint32 _queriedRoundId)
        private
        view
        returns (bool _eligible)
    {
        if (rounds[_queriedRoundId].startedAt > 0) {
            return
                acceptingSubmissions(_queriedRoundId) &&
                validateOracleRound(_oracle, _queriedRoundId).length == 0;
        } else {
            return
                delayed(_oracle, _queriedRoundId) &&
                validateOracleRound(_oracle, _queriedRoundId).length == 0;
        }
    }

    function oracleRoundStateSuggestRound(address _oracle)
        private
        view
        returns (
            bool _eligibleToSubmit,
            uint32 _roundId,
            int256 _latestSubmission,
            uint64 _startedAt,
            uint64 _timeout,
            uint128 _availableFunds,
            uint8 _oracleCount,
            uint128 _paymentAmount
        )
    {
        Round storage round = rounds[0];
        OracleStatus storage oracle = oracles[_oracle];

        bool shouldSupersede = oracle.lastReportedRound == reportingRoundId ||
            !acceptingSubmissions(reportingRoundId);
        // Instead of nudging oracles to submit to the next round, the inclusion of
        // the shouldSupersede bool in the if condition pushes them towards
        // submitting in a currently open round.
        if (supersedable(reportingRoundId) && shouldSupersede) {
            _roundId = reportingRoundId.add(1);
            round = rounds[_roundId];

            _paymentAmount = paymentAmount;
            _eligibleToSubmit = delayed(_oracle, _roundId);
        } else {
            _roundId = reportingRoundId;
            round = rounds[_roundId];

            _paymentAmount = details[_roundId].paymentAmount;
            _eligibleToSubmit = acceptingSubmissions(_roundId);
        }

        if (validateOracleRound(_oracle, _roundId).length != 0) {
            _eligibleToSubmit = false;
        }

        return (
            _eligibleToSubmit,
            _roundId,
            oracle.latestSubmission,
            round.startedAt,
            details[_roundId].timeout,
            recordedFunds.available,
            oracleCount(),
            _paymentAmount
        );
    }

    function updateRoundAnswer(uint32 _roundId)
        internal
        returns (bool, int256)
    {
        if (
            details[_roundId].submissions.length <
            details[_roundId].minSubmissions
        ) {
            return (false, 0);
        }

        int256 newAnswer = Median.calculateInplace(
            details[_roundId].submissions
        );
        rounds[_roundId].answer = newAnswer;
        rounds[_roundId].updatedAt = uint64(block.timestamp);
        rounds[_roundId].answeredInRound = _roundId;
        latestRoundId = _roundId;

        emit AnswerUpdated(newAnswer, _roundId, block.timestamp);

        return (true, newAnswer);
    }

    function payOracle(uint32 _roundId) private {
        uint128 payment = details[_roundId].paymentAmount;
        Funds memory funds = recordedFunds;
        funds.available = funds.available.sub(payment);
        funds.allocated = funds.allocated.add(payment);
        recordedFunds = funds;
        oracles[msg.sender].withdrawable = oracles[msg.sender].withdrawable.add(
            payment
        );

        emit AvailableFundsUpdated(funds.available);
    }

    function recordSubmission(int256 _submission, uint32 _roundId) private {
        require(
            acceptingSubmissions(_roundId),
            "round not accepting submissions"
        );

        details[_roundId].submissions.push(_submission);
        oracles[msg.sender].lastReportedRound = _roundId;
        oracles[msg.sender].latestSubmission = _submission;

        emit SubmissionReceived(_submission, _roundId, msg.sender);
    }

    function deleteRoundDetails(uint32 _roundId) private {
        if (
            details[_roundId].submissions.length <
            details[_roundId].maxSubmissions
        ) return;

        delete details[_roundId];
    }

    function timedOut(uint32 _roundId) private view returns (bool) {
        uint64 startedAt = rounds[_roundId].startedAt;
        uint32 roundTimeout = details[_roundId].timeout;
        return
            startedAt > 0 &&
            roundTimeout > 0 &&
            startedAt.add(roundTimeout) < block.timestamp;
    }

    function getStartingRound(address _oracle) private view returns (uint32) {
        uint32 currentRound = reportingRoundId;
        if (currentRound != 0 && currentRound == oracles[_oracle].endingRound) {
            return currentRound;
        }
        return currentRound.add(1);
    }

    function addOracle(address _oracle, address _admin) internal {
        require(!oracleEnabled(_oracle), "oracle already enabled");

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
        require(oracleEnabled(_oracle), "oracle not enabled");

        oracles[_oracle].endingRound = reportingRoundId.add(1);
        address tail = oracleAddresses[uint256(oracleCount()).sub(1)];
        uint16 index = oracles[_oracle].index;
        oracles[tail].index = index;
        delete oracles[_oracle].index;
        oracleAddresses[index] = tail;
        oracleAddresses.pop();

        emit OraclePermissionsUpdated(_oracle, false);
    }

    function previousAndCurrentUnanswered(uint32 _roundId, uint32 _rrId)
        private
        view
        returns (bool)
    {
        return _roundId.add(1) == _rrId && rounds[_rrId].updatedAt == 0;
    }

    function validateOracleRound(address _oracle, uint32 _roundId)
        private
        view
        returns (bytes memory)
    {
        // cache storage reads
        uint32 startingRound = oracles[_oracle].startingRound;
        uint32 rrId = reportingRoundId;

        if (startingRound == 0) return "not enabled oracle";
        if (startingRound > _roundId) return "not yet enabled oracle";
        if (oracles[_oracle].endingRound < _roundId)
            return "no longer allowed oracle";
        if (oracles[_oracle].lastReportedRound >= _roundId)
            return "cannot report on previous rounds";
        if (
            _roundId != rrId &&
            _roundId != rrId.add(1) &&
            !previousAndCurrentUnanswered(_roundId, rrId)
        ) return "invalid round to report";
        if (_roundId != 1 && !supersedable(_roundId.sub(1)))
            return "previous round not supersedable";
    }

    function supersedable(uint32 _roundId) private view returns (bool) {
        return rounds[_roundId].updatedAt > 0 || timedOut(_roundId);
    }

    function acceptingSubmissions(uint32 _roundId) private view returns (bool) {
        return details[_roundId].maxSubmissions != 0;
    }

    function delayed(address _oracle, uint32 _roundId)
        private
        view
        returns (bool)
    {
        uint256 lastStarted = oracles[_oracle].lastStartedRound;
        return _roundId > lastStarted + restartDelay || lastStarted == 0;
    }

    function newRound(uint32 _roundId) private view returns (bool) {
        return _roundId == reportingRoundId.add(1);
    }

    function validRoundId(uint256 _roundId) private pure returns (bool) {
        return _roundId <= ROUND_MAX;
    }

    function oracleEnabled(address _oracle) internal view returns (bool) {
        return oracles[_oracle].endingRound == ROUND_MAX;
    }

    function requiredReserve(uint256 payment) internal view override returns (uint256) {
        return payment.mul(oracleCount()).mul(RESERVE_ROUNDS);
    }
}
