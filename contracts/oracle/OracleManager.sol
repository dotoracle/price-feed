pragma solidity ^0.7.0;

contract OracleManager {
    struct OracleStatus {
        uint128 paymentDebt;
        uint32 startingRound;
        uint32 endingRound;
        uint16 index;
        address admin;
        address pendingAdmin;
    }

    uint128 public accPaymentPerOracle;

    mapping(address => OracleStatus) internal oracles;
    address[] internal oracleAddresses;

    event OraclePermissionsUpdated(
        address indexed oracle,
        bool indexed whitelisted
    );
    event OracleAdminUpdated(address indexed oracle, address indexed newAdmin);
    event OracleAdminUpdateRequested(
        address indexed oracle,
        address admin,
        address newAdmin
    );

    /**
     * @notice returns the number of oracles
     */
    function oracleCount() public view returns (uint8) {
        return uint8(oracleAddresses.length);
    }

    /**
     * @notice returns an array of addresses containing the oracles on contract
     */
    function getOracles() external view returns (address[] memory) {
        return oracleAddresses;
    }
    
}
