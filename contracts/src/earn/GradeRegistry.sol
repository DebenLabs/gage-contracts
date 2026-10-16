// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Collateral grades published from the valuation service, read by Earn strategies with a minimum grade.
/// @dev A grade is a rank from 1 (D) to 10 (AAA); 0 is unrated. A grade older than `MAX_AGE` reads as unrated, so a
/// stopped publisher cannot keep a token admissible. Nothing here moves value: a strategy only refuses new loans.
contract GradeRegistry is Ownable {
    struct Grade {
        uint8 rank;
        uint40 updatedAt;
    }

    uint8 public constant MAX_GRADE = 10;
    uint40 public constant MAX_AGE = 7 days;

    address public publisher;
    mapping(address => Grade) public grades;

    /// @dev The model's cost of a reference loan against one token for one term, in basis points of principal (D127).
    struct Cost {
        uint32 bps;
        uint40 updatedAt;
    }

    mapping(address => mapping(uint32 => Cost)) public modeledCosts;

    event PublisherSet(address indexed publisher);
    event GradeSet(address indexed token, uint8 rank);
    event ModeledCostSet(address indexed token, uint32 term, uint32 bps);

    error NotPublisher();
    error InvalidGrade();
    error LengthMismatch();

    constructor(address initialOwner, address initialPublisher) Ownable(initialOwner) {
        publisher = initialPublisher;
        emit PublisherSet(initialPublisher);
    }

    /// @notice Name the key that publishes grades.
    function setPublisher(address account) external onlyOwner {
        publisher = account;
        emit PublisherSet(account);
    }

    /// @notice Publish grades for tokens; 0 withdraws a grade.
    function setGrades(address[] calldata tokens, uint8[] calldata ranks) external {
        if (msg.sender != publisher) revert NotPublisher();
        if (tokens.length != ranks.length) revert LengthMismatch();
        for (uint256 i; i < tokens.length; ++i) {
            if (ranks[i] > MAX_GRADE) revert InvalidGrade();
            grades[tokens[i]] = Grade(ranks[i], uint40(block.timestamp));
            emit GradeSet(tokens[i], ranks[i]);
        }
    }

    /// @notice The token's current rank, 0 when unrated or older than `MAX_AGE`.
    /// @notice Publish the model's cost per token and term; a zero cost withdraws the model's opinion (D127).
    function setModeledCosts(address[] calldata tokens, uint32[] calldata terms, uint32[] calldata bps) external {
        if (msg.sender != publisher) revert NotPublisher();
        if (tokens.length != terms.length || tokens.length != bps.length) revert LengthMismatch();
        for (uint256 i; i < tokens.length; ++i) {
            modeledCosts[tokens[i]][terms[i]] = Cost(bps[i], uint40(block.timestamp));
            emit ModeledCostSet(tokens[i], terms[i], bps[i]);
        }
    }

    /// @notice The modeled cost of a token for a term, or zero once it is older than `MAX_AGE` or was never published.
    function modeledCostOf(address token, uint32 term) external view returns (uint32) {
        Cost memory c = modeledCosts[token][term];
        return block.timestamp - c.updatedAt > MAX_AGE ? 0 : c.bps;
    }

    function gradeOf(address token) external view returns (uint8) {
        Grade memory g = grades[token];
        return block.timestamp - g.updatedAt > MAX_AGE ? 0 : g.rank;
    }
}
