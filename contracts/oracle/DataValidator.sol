pragma solidity ^0.7.0;

import "../interfaces/IDataValidate.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DataValidator is Ownable {
    IDataValidate public validator;
    event ValidatorUpdated(address indexed previous, address indexed current);

    /**
     * @notice method to update the address which does external data validation.
     * @param _newValidator designates the address of the new validation contract.
     */
    function setValidator(address _newValidator) public onlyOwner() {
        address previous = address(validator);

        if (previous != _newValidator) {
            validator = IDataValidate(_newValidator);

            emit ValidatorUpdated(previous, _newValidator);
        }
    }
}
