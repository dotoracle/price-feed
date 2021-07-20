// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

interface IPriceFeed {
    function description() external view returns (string memory);

    function version() external view returns (uint256);

    // getRoundData and latestRoundData should both raise "No data present"
    // if they do not have data to report, instead of returning unset values
    // which could be misinterpreted as actual reported values.
    function getRoundInfo(uint80 _roundId)
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function latestRoundInfo()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function latestAnswer() external view returns (int256);

    function latestUpdated() external view returns (uint256);

    function latestRound() external view returns (uint256);

    function getAnswerByRound(uint256 roundId) external view returns (int256);

    function getUpdatedTime(uint256 roundId) external view returns (uint256);

    event AnswerUpdated(
        int256 indexed current,
        uint256 indexed roundId,
        uint256 updatedAt
    );

    event NewRound(
        uint256 indexed roundId,
        address indexed startedBy,
        uint256 startedAt
    );
}
