// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {NameCoder} from "@ensdomains/ens-contracts/contracts/utils/NameCoder.sol";
import {ITextResolver} from "@ensdomains/ens-contracts/contracts/resolvers/profiles/ITextResolver.sol";
import {IUniversalResolver} from "@ensdomains/ens-contracts/contracts/universalResolver/IUniversalResolver.sol";

import {Aggregator} from "../src/Aggregator.sol";
import {GovernanceAggregator} from "../src/GovernanceAggregator.sol";
import {Relayer} from "../src/RelayerAggregator.sol";
import {IGovernance} from "../src/interfaces/IGovernance.sol";
import {IRelayerRegistry} from "../src/interfaces/IRelayerRegistry.sol";

/// @dev Minimal IGovernance mock (1-based proposal ids, like the real contract).
contract MockGovernance {
    struct P {
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

    P[] internal _p;
    mapping(address => uint256) public lockedBalance;
    mapping(address => uint256) public latestProposalIds;
    mapping(address => uint256) public canWithdrawAfter;
    mapping(address => address) public delegatedTo;

    function addProposal(P memory p) external {
        _p.push(p);
    }

    function setUser(address a, uint256 bal, uint256 latest, uint256 timelock, address delegatee) external {
        lockedBalance[a] = bal;
        latestProposalIds[a] = latest;
        canWithdrawAfter[a] = timelock;
        delegatedTo[a] = delegatee;
    }

    function proposalCount() external view returns (uint256) {
        return _p.length;
    }

    function proposals(uint256 id)
        external
        view
        returns (address, address, uint256, uint256, uint256, uint256, bool, bool)
    {
        require(id >= 1 && id <= _p.length, "bad id");
        P storage p = _p[id - 1];
        return (p.proposer, p.target, p.startTime, p.endTime, p.forVotes, p.againstVotes, p.executed, p.extended);
    }

    function state(uint256 id) external view returns (IGovernance.ProposalState) {
        require(id >= 1 && id <= _p.length, "bad id");
        return _p[id - 1].state;
    }
}

/// @dev Mock Universal Resolver: answers keyed by (dnsName, calldata); unknown keys revert
///      with ResolverNotFound like the real one.
contract MockUR {
    mapping(bytes32 => bytes) internal answers;
    mapping(bytes32 => bool) internal known;

    function setAnswer(bytes memory name, bytes memory data, bytes memory result) external {
        bytes32 k = keccak256(abi.encode(name, data));
        answers[k] = result;
        known[k] = true;
    }

    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory, address) {
        bytes32 k = keccak256(abi.encode(name, data));
        if (!known[k]) revert IUniversalResolver.ResolverNotFound(name);
        return (answers[k], address(0xBEEF));
    }
}

/// @dev Separate ENSv2 UniversalHelper mock.
///      It intentionally lives at a different address from the Universal Resolver.
contract MockUniversalHelper {
    bool public enabled;
    mapping(bytes32 => address) internal owners;

    function setEnabled(bool on) external {
        enabled = on;
    }

    function setOwner(bytes memory name, address owner) external {
        owners[keccak256(name)] = owner;
    }

    function findExactOwner(bytes calldata name) external view returns (address) {
        require(enabled, "UniversalHelper: unavailable");
        return owners[keccak256(name)];
    }
}

contract MockEnsRegistry {
    mapping(bytes32 => address) public owner;

    function setOwner(bytes32 node, address o) external {
        owner[node] = o;
    }
}

contract MockRelayerRegistry {
    mapping(address => uint256) public getRelayerBalance;
    mapping(address => bool) public registered;

    function set(address r, bool isReg, uint256 bal) external {
        registered[r] = isReg;
        getRelayerBalance[r] = bal;
    }

    function isRelayerRegistered(address relayer, address toResolve) external view returns (bool) {
        return relayer == toResolve && registered[relayer];
    }
}

contract AggregatorTest is Test {
    // Hardcoded in RelayerAggregator
    address constant UR = 0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe;
    address constant UNIVERSAL_HELPER = 0x46AE127D14683Ac74eF151e46ae2117A1A25C676;
    address constant REGISTRY = 0x58E8dCC13BE9780fC42E8723D8EaD4CF46943dF2;
    address constant ENS_V1 = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;

    Aggregator aggregator;
    MockGovernance gov;
    MockUR ur = MockUR(UR);
    MockUniversalHelper helper = MockUniversalHelper(UNIVERSAL_HELPER);
    MockRelayerRegistry registry = MockRelayerRegistry(REGISTRY);
    MockEnsRegistry ensV1 = MockEnsRegistry(ENS_V1);

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address relayerA = makeAddr("relayerA");
    address relayerB = makeAddr("relayerB");

    function setUp() public {
        // Place mocks at the hardcoded mainnet addresses (storage is then written at those addresses).
        vm.etch(UR, address(new MockUR()).code);
        vm.etch(UNIVERSAL_HELPER, address(new MockUniversalHelper()).code);
        vm.etch(REGISTRY, address(new MockRelayerRegistry()).code);
        vm.etch(ENS_V1, address(new MockEnsRegistry()).code);

        aggregator = new Aggregator();
        gov = new MockGovernance();
    }

    // ───────────────────────── helpers ─────────────────────────

    /// @dev Owner as seen by the ENSv1 registry.
    function _setOwnerV1(string memory name, address a) internal {
        ensV1.setOwner(NameCoder.namehash(NameCoder.encode(name), 0), a);
    }

    /// @dev Owner as seen by the separate ENSv2 UniversalHelper (also switches v2 on).
    function _setOwnerV2(string memory name, address a) internal {
        helper.setEnabled(true);
        helper.setOwner(NameCoder.encode(name), a);
    }

    function _setUrl(string memory fullName, string memory url) internal {
        bytes memory dns = NameCoder.encode(fullName);
        ur.setAnswer(dns, abi.encodeCall(ITextResolver.text, (NameCoder.namehash(dns, 0), "url")), abi.encode(url));
    }

    function _addProposal(address proposer, uint256 forV, uint256 againstV, bool executed, IGovernance.ProposalState st)
        internal
    {
        gov.addProposal(
            MockGovernance.P({
                proposer: proposer,
                target: address(0x1234),
                startTime: 100,
                endTime: 200,
                forVotes: forV,
                againstVotes: againstV,
                executed: executed,
                extended: false,
                state: st
            })
        );
    }

    // ───────────────────── GovernanceAggregator ─────────────────────

    function test_getAllProposals_empty() public view {
        GovernanceAggregator.Proposal[] memory ps = aggregator.getAllProposals(IGovernance(address(gov)));
        assertEq(ps.length, 0);
    }

    function test_getAllProposals() public {
        _addProposal(alice, 10, 1, true, IGovernance.ProposalState.Executed);
        _addProposal(bob, 5, 7, false, IGovernance.ProposalState.Defeated);

        GovernanceAggregator.Proposal[] memory ps = aggregator.getAllProposals(IGovernance(address(gov)));
        assertEq(ps.length, 2);

        assertEq(ps[0].proposer, alice);
        assertEq(ps[0].target, address(0x1234));
        assertEq(ps[0].startTime, 100);
        assertEq(ps[0].endTime, 200);
        assertEq(ps[0].forVotes, 10);
        assertEq(ps[0].againstVotes, 1);
        assertTrue(ps[0].executed);
        assertFalse(ps[0].extended);
        assertEq(uint256(ps[0].state), uint256(IGovernance.ProposalState.Executed));

        assertEq(ps[1].proposer, bob);
        assertEq(ps[1].forVotes, 5);
        assertEq(ps[1].againstVotes, 7);
        assertFalse(ps[1].executed);
        assertEq(uint256(ps[1].state), uint256(IGovernance.ProposalState.Defeated));
    }

    function test_getGovernanceBalances() public {
        gov.setUser(alice, 100 ether, 0, 0, address(0));
        gov.setUser(bob, 5 ether, 0, 0, address(0));

        address[] memory accs = new address[](3);
        accs[0] = alice;
        accs[1] = bob;
        accs[2] = makeAddr("nobody");

        uint256[] memory amounts = aggregator.getGovernanceBalances(IGovernance(address(gov)), accs);
        assertEq(amounts.length, 3);
        assertEq(amounts[0], 100 ether);
        assertEq(amounts[1], 5 ether);
        assertEq(amounts[2], 0);
    }

    function test_getUserData_withProposal() public {
        _addProposal(alice, 1, 0, false, IGovernance.ProposalState.AwaitingExecution);
        gov.setUser(alice, 42 ether, 1, 999, bob);

        (uint256 balance, uint256 latestId, uint256 latestState, uint256 timelock, address delegatee) =
            aggregator.getUserData(IGovernance(address(gov)), alice);

        assertEq(balance, 42 ether);
        assertEq(latestId, 1);
        assertEq(latestState, uint256(IGovernance.ProposalState.AwaitingExecution));
        assertEq(timelock, 999);
        assertEq(delegatee, bob);
    }

    function test_getUserData_noProposal() public {
        gov.setUser(alice, 1 ether, 0, 0, address(0));
        (uint256 balance, uint256 latestId, uint256 latestState, uint256 timelock, address delegatee) =
            aggregator.getUserData(IGovernance(address(gov)), alice);
        assertEq(balance, 1 ether);
        assertEq(latestId, 0);
        assertEq(latestState, 0); // not queried when there is no proposal
        assertEq(timelock, 0);
        assertEq(delegatee, address(0));
    }

    // ───────────────────── RelayerAggregator ─────────────────────

    function test_constants() public view {
        assertEq(address(aggregator.universalResolver()), UR);
        assertEq(address(aggregator.universalHelper()), UNIVERSAL_HELPER);
        assertEq(address(aggregator.ensRegistry()), ENS_V1);
        assertEq(address(aggregator.relayerRegistry()), REGISTRY);
        assertEq(aggregator.MAX_RECORDS(), 20);
    }

    function test_relayersData() public {
        _setOwnerV1("alice.tornadocash.eth", relayerA);
        _setUrl("mainnet-tornado.alice.tornadocash.eth", "https://alice.example");
        _setUrl("bsc-tornado.alice.tornadocash.eth", "https://alice-bsc.example");
        registry.set(relayerA, true, 3000 ether);

        _setOwnerV1("bob.tornadocash.eth", relayerB);
        _setUrl("mainnet-tornado.bob.tornadocash.eth", "https://bob.example");
        // bob has no bsc record and is not registered
        registry.set(relayerB, false, 0);

        string[] memory names = new string[](2);
        names[0] = "alice.tornadocash.eth";
        names[1] = "bob.tornadocash.eth";
        string[] memory subs = new string[](2);
        subs[0] = "mainnet-tornado";
        subs[1] = "bsc-tornado";

        Relayer[] memory r = aggregator.relayersData(names, subs);
        assertEq(r.length, 2);

        assertEq(r[0].owner, relayerA);
        assertTrue(r[0].isRegistered);
        assertEq(r[0].balance, 3000 ether);
        assertEq(r[0].records[0], "https://alice.example");
        assertEq(r[0].records[1], "https://alice-bsc.example");
        assertEq(r[0].records[2], "");

        assertEq(r[1].owner, relayerB);
        assertFalse(r[1].isRegistered);
        assertEq(r[1].balance, 0);
        assertEq(r[1].records[0], "https://bob.example");
        assertEq(r[1].records[1], ""); // missing record -> empty, no revert
    }

    function test_relayersData_unresolvableNameDoesNotRevertBatch() public {
        _setOwnerV1("alice.tornadocash.eth", relayerA);
        registry.set(relayerA, true, 1 ether);
        // "ghost.tornadocash.eth" has no owner and no records anywhere

        string[] memory names = new string[](2);
        names[0] = "ghost.tornadocash.eth";
        names[1] = "alice.tornadocash.eth";

        Relayer[] memory r = aggregator.relayersData(names, new string[](0));
        assertEq(r[0].owner, address(0));
        assertFalse(r[0].isRegistered);
        assertEq(r[0].balance, 0);
        assertEq(r[1].owner, relayerA);
        assertTrue(r[1].isRegistered);
    }

    function test_owner_v2PreferredOverV1() public {
        _setOwnerV1("alice.tornadocash.eth", relayerB);
        _setOwnerV2("alice.tornadocash.eth", relayerA);
        registry.set(relayerA, true, 7 ether);

        string[] memory names = new string[](1);
        names[0] = "alice.tornadocash.eth";
        Relayer[] memory r = aggregator.relayersData(names, new string[](0));
        assertEq(r[0].owner, relayerA);
        assertTrue(r[0].isRegistered);
        assertEq(r[0].balance, 7 ether);
    }

    function test_owner_fallsBackToV1_whenV2Reverts() public {
        // v2 helper not enabled -> findExactOwner reverts, so ENSv1 is used.
        _setOwnerV1("alice.tornadocash.eth", relayerA);
        string[] memory names = new string[](1);
        names[0] = "alice.tornadocash.eth";
        Relayer[] memory r = aggregator.relayersData(names, new string[](0));
        assertEq(r[0].owner, relayerA);
    }

    function test_owner_fallsBackToV1_whenV2ReturnsZero() public {
        _setOwnerV1("alice.tornadocash.eth", relayerA);
        helper.setEnabled(true); // enabled, but no v2 owner for this name
        string[] memory names = new string[](1);
        names[0] = "alice.tornadocash.eth";
        Relayer[] memory r = aggregator.relayersData(names, new string[](0));
        assertEq(r[0].owner, relayerA);
    }

    function test_owner_zeroWhenNoOwnerAnywhere() public view {
        string[] memory names = new string[](1);
        names[0] = "nobody.tornadocash.eth";
        Relayer[] memory r = aggregator.relayersData(names, new string[](0));
        assertEq(r[0].owner, address(0));
        assertFalse(r[0].isRegistered);
        assertEq(r[0].balance, 0);
    }

    function test_relayersData_noNames() public view {
        Relayer[] memory r = aggregator.relayersData(new string[](0), new string[](0));
        assertEq(r.length, 0);
    }

    function test_relayersData_maxSubdomains() public {
        _setOwnerV1("alice.tornadocash.eth", relayerA);
        string[] memory names = new string[](1);
        names[0] = "alice.tornadocash.eth";

        string[] memory subs = new string[](20);
        for (uint256 i = 0; i < 20; i++) {
            subs[i] = "x";
        }
        aggregator.relayersData(names, subs); // exactly 20 is fine

        string[] memory tooMany = new string[](21);
        for (uint256 i = 0; i < 21; i++) {
            tooMany[i] = "x";
        }
        vm.expectRevert("RelayerAggregator: too many subdomains");
        aggregator.relayersData(names, tooMany);
    }

    function test_relayersData_invalidNameReverts() public {
        string[] memory names = new string[](1);
        names[0] = "alice..eth"; // empty label
        vm.expectRevert(abi.encodeWithSelector(NameCoder.DNSEncodingFailed.selector, "alice..eth"));
        aggregator.relayersData(names, new string[](0));
    }

    function test_relayersData_emptySubdomainLabelReverts() public {
        _setOwnerV1("alice.tornadocash.eth", relayerA);
        string[] memory names = new string[](1);
        names[0] = "alice.tornadocash.eth";
        string[] memory subs = new string[](1);
        subs[0] = "";
        vm.expectRevert(NameCoder.LabelIsEmpty.selector);
        aggregator.relayersData(names, subs);
    }

    // ───────────────────── NameCoder sanity ─────────────────────

    /// @dev Independent check against the well-known namehash of "eth" (EIP-137).
    function test_namehashKnownVectors() public pure {
        assertEq(
            NameCoder.namehash(NameCoder.encode("eth"), 0),
            0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae
        );
        assertEq(NameCoder.namehash(NameCoder.encode(""), 0), bytes32(0));
        assertEq(
            NameCoder.namehash(NameCoder.encode("foo.eth"), 0),
            0xde9b09fd7c5f901e23a3f19fecc54828e9c848539801e86591bd9801b019f84f
        );
    }

    /// @dev Child name built with addLabel must equal encoding the full dotted name.
    function test_subdomainEncodingMatchesFullName() public pure {
        bytes memory parent = NameCoder.encode("alice.tornadocash.eth");
        assertEq(
            NameCoder.addLabel(parent, "mainnet-tornado"), NameCoder.encode("mainnet-tornado.alice.tornadocash.eth")
        );
    }
}
