// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IGovernance} from "./interfaces/IGovernance.sol";

contract GovernanceAggregator {
    struct Proposal {
        address proposer;
        address target;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bool extended;
        IGovernance.ProposalState state;
    }

    function getAllProposals(IGovernance governance) public view returns (Proposal[] memory proposals) {
        proposals = new Proposal[](governance.proposalCount());

        for (uint256 i = 0; i < proposals.length; i++) {
            uint256 id = i + 1;
            (
                address proposer,
                address target,
                uint256 startTime,
                uint256 endTime,
                uint256 forVotes,
                uint256 againstVotes,
                bool executed,
                bool extended
            ) = governance.proposals(id);

            proposals[i] = Proposal({
                proposer: proposer,
                target: target,
                startTime: startTime,
                endTime: endTime,
                forVotes: forVotes,
                againstVotes: againstVotes,
                executed: executed,
                extended: extended,
                state: governance.state(id)
            });
        }
    }

    function getGovernanceBalances(IGovernance governance, address[] calldata accs)
        public
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](accs.length);
        for (uint256 i = 0; i < accs.length; i++) {
            amounts[i] = governance.lockedBalance(accs[i]);
        }
    }

    function getUserData(IGovernance governance, address account)
        public
        view
        returns (
            uint256 balance,
            uint256 latestProposalId,
            uint256 latestProposalIdState,
            uint256 timelock,
            address delegatee
        )
    {
        balance = governance.lockedBalance(account);
        latestProposalId = governance.latestProposalIds(account);
        if (latestProposalId != 0) {
            latestProposalIdState = uint256(governance.state(latestProposalId));
        }
        timelock = governance.canWithdrawAfter(account);
        delegatee = governance.delegatedTo(account);
    }
}
