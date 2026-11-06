// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GovernanceAggregator} from "./GovernanceAggregator.sol";
import {RelayerAggregator} from "./RelayerAggregator.sol";

contract Aggregator is GovernanceAggregator, RelayerAggregator {}
