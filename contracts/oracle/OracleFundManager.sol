pragma solidity ^0.7.0;
import "./OracleManager.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../lib/math/SafeMath128.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

abstract contract OracleFundManager is OracleManager, Ownable {
    using SafeMath128 for uint128;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    struct Funds {
        uint128 available;
        uint128 allocated;
    }
    IERC20 public dtoToken;
    Funds internal recordedFunds;
    uint128 public paymentAmount;

    event AvailableFundsUpdated(uint256 indexed amount);

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
     * @notice the amount of payment yet to be withdrawn by oracles
     */
    function allocatedFunds() external view returns (uint128) {
        return recordedFunds.allocated;
    }

    /**
     * @notice the amount of future funding available to oracles
     */
    function availableFunds() external view returns (uint128) {
        return recordedFunds.available;
    }

    /**
     * @notice recalculate the amount of DTO available for payouts
     */
    function updateAvailableFunds() public {
        Funds memory funds = recordedFunds;

        uint256 nowAvailable = dtoToken.balanceOf(address(this)).sub(
            funds.allocated
        );

        if (funds.available != nowAvailable) {
            recordedFunds.available = uint128(nowAvailable);
            emit AvailableFundsUpdated(nowAvailable);
        }
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

    /**
     * @notice transfers the owner's DTO to another address
     * @param _recipient is the address to send the DTO to
     * @param _amount is the amount of DTO to send
     */
    function withdrawFunds(address _recipient, uint256 _amount)
        external
        onlyOwner()
    {
        uint256 available = uint256(recordedFunds.available);
        require(
            available.sub(computeRequiredReserve(paymentAmount)) >= _amount,
            "insufficient reserve funds"
        );
        dtoToken.safeTransfer(_recipient, _amount);
        updateAvailableFunds();
    }

    function computeRequiredReserve(uint256 payment)
        internal
        view
        virtual
        returns (uint256);
}
