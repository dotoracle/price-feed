// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "../lib/math/Median.sol";
import "../lib/math/SafeMath128.sol";
import "../lib/math/SafeMath32.sol";
import "../lib/math/SafeMath64.sol";
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
contract OraclePaymentManager is PriceChecker, OracleFundManager, PFConfig {
    using SafeMath for uint256;
    using SafeMath128 for uint128;
    using SafeMath64 for uint64;
    using SafeMath32 for uint32;
    using SafeERC20 for IERC20;
    using EOACheck for address;

    uint32 internal lastReportedRound;

    event RoundSettingsUpdated(uint128 indexed paymentAmount);

    function initialize(address _dto, uint128 _paymentAmount) internal {
        dtoToken = IERC20(_dto);
        updateFutureRounds(_paymentAmount);
    }

    /**
     * @notice transfers the oracle's DTO to another address. Can only be called
     * by the oracle's admin.
     * @param _oracle is the oracle whose DTO is transferred
     * @param _recipient is the address to send the DTO to
     * @param _amount is the amount of DTO to send
     */
    function withdrawPayment(
        address _oracle,
        address _recipient,
        uint256 _amount
    ) external {
        require(oracles[_oracle].admin == msg.sender, "only callable by admin");

        // Safe to downcast _amount because the total amount of DTO is less than 2^128.
        uint128 amount = uint128(_amount);
        uint128 available = oracles[_oracle].withdrawable;
        require(available >= amount, "insufficient withdrawable funds");

        oracles[_oracle].withdrawable = available.sub(amount);
        recordedFunds.allocated = recordedFunds.allocated.sub(amount);

        dtoToken.safeTransfer(_recipient, uint256(amount));
    }

    /**
     * @notice query the available amount of DTO for an oracle to withdraw
     */
    function withdrawablePayment(address _oracle)
        external
        view
        returns (uint256)
    {
        return oracles[_oracle].withdrawable;
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
     */
    function changeOracles(
        address[] calldata _removed,
        address[] calldata _added,
        address[] calldata _addedAdmins
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

        updateFutureRounds(paymentAmount);
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
     */
    function updateFutureRounds(uint128 _paymentAmount) public onlyOwner() {
        require(
            recordedFunds.available >= computeRequiredReserve(_paymentAmount),
            "PriceFeedOracle::updateFutureRounds insufficient funds for payment"
        );

        paymentAmount = _paymentAmount;

        emit RoundSettingsUpdated(paymentAmount);
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

    function computeRequiredReserve(uint256 payment)
        internal
        view
        override
        returns (uint256)
    {
        return payment.mul(oracleCount()).mul(RESERVE_ROUNDS);
    }

    function isOracleEnabled(address _oracle) internal view returns (bool) {
        return oracles[_oracle].endingRound == ROUND_MAX;
    }

    function getStartingRound(address _oracle) internal view returns (uint32) {
        uint32 currentRound = lastReportedRound;
        if (currentRound != 0 && currentRound == oracles[_oracle].endingRound) {
            return currentRound;
        }
        return currentRound.add(1);
    }
}
