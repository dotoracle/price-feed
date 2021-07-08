pragma solidity ^0.7.0;

library EOACheck {
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(account) }
        return size > 0;
    } 


    function isCalledFromEOA(address account) internal view returns (bool) {
        return !isContract(account) && account== tx.origin;
    }
}