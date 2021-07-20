pragma solidity ^0.7.0;


abstract contract PFConfig {
  int256 immutable public minSubmissionValue;
  int256 immutable public maxSubmissionValue;
  /**
   * @notice To ensure owner isn't withdrawing required funds as oracles are
   * submitting updates, we enforce that the contract maintains a minimum
   * reserve of RESERVE_ROUNDS * oracleCount() DTO earmarked for payment to
   * oracles. (Of course, this doesn't prevent the contract from running out of
   * funds without the owner's intervention.)
   */
  uint256 constant public RESERVE_ROUNDS = 2;
  uint256 constant public MAX_ORACLE_COUNT = 77;
  uint32 constant public ROUND_MAX = 2**32-1;
  uint256 public constant VALIDATOR_GAS_LIMIT = 100000;
  // An error specific to the Aggregator V3 Interface, to prevent possible
  // confusion around accidentally reading unset values as reported values.
  string constant public V3_NO_DATA_ERROR = "No data present";

  constructor(int256 _minSubmissionValue, int256 _maxSubmissionValue) internal {
      minSubmissionValue = _minSubmissionValue;
      maxSubmissionValue = _maxSubmissionValue;
  }
}