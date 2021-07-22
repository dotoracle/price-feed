// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

interface IMultiPriceFeed {
    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundInfo(uint80 _roundId)
        external
        view
        returns (
            uint80 roundId,
            int256[] memory answers,
            uint256 updatedAt
        );

    function getRoundInfoOfToken(uint32 _tokenIndex, uint80 _roundId)
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 updatedAt
        );

    function latestRoundInfo()
        external
        view
        returns (
            uint80 roundId,
            int256[] memory answers,
            uint256 updatedAt
        );

    function latestRoundInfoOfToken(uint32 _tokenIndex)
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 updatedAt
        );

    function latestAnswer() external view returns (int256[] memory);
    function latestAnswerOfToken(uint32 _tokenIndex) external view returns (int256);

    function latestUpdated() external view returns (uint256);

    function latestRound() external view returns (uint256);

    function getAnswerByRound(uint256 roundId) external view returns (int256[] memory);
    function getAnswerByRoundOfToken(uint32 _tokenIndex, uint256 roundId) external view returns (int256);

    function getUpdatedTime(uint256 roundId) external view returns (uint256);

    event AnswerUpdated(
        uint256 indexed roundId,
        bytes indexed current,   //encode packed of new answers
        uint256 updatedAt
    );
}
