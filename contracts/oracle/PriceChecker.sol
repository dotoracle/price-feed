pragma solidity ^0.7.0;

import "../interfaces/IDataChecker.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PriceChecker is Ownable {
    IDataChecker public checker;
    event ValidatorUpdated(address indexed previous, address indexed current);

    /**
     * @notice method to update the address which does external data checker.
     * @param _checker designates the address of the new check contract.
     */
    function setChecker(address _checker) public onlyOwner() {
        address previous = address(checker);

        if (previous != _checker) {
            checker = IDataChecker(_checker);

            emit ValidatorUpdated(previous, _checker);
        }
    }
}
