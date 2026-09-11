// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockAggregator
/// @notice Chainlink AggregatorV3-compatible feed for local development and tests. Besides normal
///         price updates it can simulate each oracle failure mode the OracleManager must handle:
///         stale data, future timestamps, invalid answers, incomplete rounds and outright reverts.
/// @dev Emits Chainlink's own `AnswerUpdated`/`NewRound` events so the indexer handles mocks and real
///      aggregators identically. LOCAL / TESTNET ONLY: the owner controls the price.
contract MockAggregator is AggregatorV3Interface, Ownable {
    struct Round {
        int256 answer;
        uint64 startedAt;
        uint64 updatedAt;
    }

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event NewRound(uint256 indexed roundId, address indexed startedBy, uint256 startedAt);

    error FeedReverting();
    error RoundNotFound();

    uint8 public immutable decimals;
    uint256 public constant version = 4;
    string public description;

    uint80 public latestRound;
    bool public reverting;
    mapping(uint80 roundId => Round) internal _rounds;

    constructor(uint8 decimals_, string memory description_, int256 initialAnswer, address owner_)
        Ownable(owner_)
    {
        decimals = decimals_;
        description = description_;
        _pushRound(initialAnswer, block.timestamp);
    }

    /// @notice Post a new answer timestamped now.
    function setAnswer(int256 answer) external onlyOwner {
        _pushRound(answer, block.timestamp);
    }

    /// @notice Post a new answer with an arbitrary timestamp (stale / future simulations).
    function setAnswerWithTimestamp(int256 answer, uint256 updatedAt) external onlyOwner {
        _pushRound(answer, updatedAt);
    }

    /// @notice Re-post the current answer with a fresh timestamp: a heartbeat for long-running demos.
    function poke() external onlyOwner {
        _pushRound(_rounds[latestRound].answer, block.timestamp);
    }

    /// @notice Simulate an incomplete round (updatedAt == 0) without changing the answer.
    function setIncompleteRound() external onlyOwner {
        _rounds[latestRound].updatedAt = 0;
    }

    /// @notice Make every read revert, e.g. a deprecated or access-controlled aggregator.
    function setReverting(bool reverting_) external onlyOwner {
        reverting = reverting_;
    }

    function latestAnswer() external view returns (int256) {
        return _rounds[latestRound].answer;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (reverting) revert FeedReverting();
        Round memory r = _rounds[latestRound];
        return (latestRound, r.answer, r.startedAt, r.updatedAt, latestRound);
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        if (reverting) revert FeedReverting();
        if (roundId == 0 || roundId > latestRound) revert RoundNotFound();
        Round memory r = _rounds[roundId];
        return (roundId, r.answer, r.startedAt, r.updatedAt, roundId);
    }

    function _pushRound(int256 answer, uint256 updatedAt) internal {
        uint80 roundId = ++latestRound;
        // Test double: timestamps are caller-controlled and far below 2^64.
        // forge-lint: disable-next-line(unsafe-typecast)
        _rounds[roundId] = Round({answer: answer, startedAt: uint64(updatedAt), updatedAt: uint64(updatedAt)});
        emit NewRound(roundId, msg.sender, updatedAt);
        emit AnswerUpdated(answer, roundId, updatedAt);
    }
}
