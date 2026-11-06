// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice Minimal read-only view of the Tornado Cash Governance contract.
/// @dev Only the getters the aggregator needs. Selectors match the deployed
///      Governance (v1) ABI, so no governance source needs to be vendored.
interface IGovernance {
    enum ProposalState {
        Pending,
        Active,
        Defeated,
        Timelocked,
        AwaitingExecution,
        Executed,
        Expired
    }

    function proposalCount() external view returns (uint256);

    /// @dev 1-based proposal id (id 0 is not a proposal).
    function proposals(uint256 proposalId)
        external
        view
        returns (
            address proposer,
            address target,
            uint256 startTime,
            uint256 endTime,
            uint256 forVotes,
            uint256 againstVotes,
            bool executed,
            bool extended
        );

    function state(uint256 proposalId) external view returns (ProposalState);

    function lockedBalance(address account) external view returns (uint256);

    function latestProposalIds(address account) external view returns (uint256);

    function canWithdrawAfter(address account) external view returns (uint256);

    function delegatedTo(address account) external view returns (address);
}
