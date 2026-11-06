// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IUniversalResolver} from "@ensdomains/ens-contracts/contracts/universalResolver/IUniversalResolver.sol";
import {ENS} from "@ensdomains/ens-contracts/contracts/registry/ENS.sol";
import {ITextResolver} from "@ensdomains/ens-contracts/contracts/resolvers/profiles/ITextResolver.sol";
import {NameCoder} from "@ensdomains/ens-contracts/contracts/utils/NameCoder.sol";
import {IRelayerRegistry} from "./interfaces/IRelayerRegistry.sol";

/// @notice ENSv2 UniversalHelper interface.
/// @dev UniversalHelper is a separate contract from UniversalResolver.
interface IUniversalHelper {
    function findExactOwner(bytes calldata name) external view returns (address);
}

struct Relayer {
    address owner; // owner of the relayer name (ENSv2 first, ENSv1 registry as fallback)
    uint256 balance;
    bool isRegistered;
    string[20] records;
}

/// @notice Batch reader for relayer data. Names are human-readable ENS names
///         (e.g. "alice.tornadocash.eth"), NOT namehashes, and must already be
///         ENSIP-15 normalized off-chain (NameCoder only encodes, it does not normalize).
contract RelayerAggregator {
    uint256 public constant MAX_RECORDS = 20;
    string internal constant URL_KEY = "url";

    /// @notice ENS Universal Resolver proxy (Ethereum mainnet).
    ///         Used for text record resolution.
    IUniversalResolver public constant universalResolver =
        IUniversalResolver(0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe);

    /// @notice ENSv2 UniversalHelper (Ethereum mainnet).
    ///         Separate contract providing findExactOwner().
    IUniversalHelper public constant universalHelper = IUniversalHelper(0x46AE127D14683Ac74eF151e46ae2117A1A25C676);

    /// @notice ENSv1 registry (Ethereum mainnet).
    ENS public constant ensRegistry = ENS(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e);

    /// @notice Tornado Cash RelayerRegistry (Ethereum mainnet).
    IRelayerRegistry public constant relayerRegistry = IRelayerRegistry(0x58E8dCC13BE9780fC42E8723D8EaD4CF46943dF2);

    /// @param relayerNames ENS names of the relayers, e.g. "alice.tornadocash.eth".
    /// @param subdomains Single labels prepended to each relayer name, e.g. "mainnet-tornado" ->
    ///        "mainnet-tornado.alice.tornadocash.eth", whose `url` text record is returned in `records[j]`.
    function relayersData(string[] memory relayerNames, string[] memory subdomains)
        public
        view
        returns (Relayer[] memory)
    {
        require(subdomains.length <= MAX_RECORDS, "RelayerAggregator: too many subdomains");

        Relayer[] memory relayers = new Relayer[](relayerNames.length);

        for (uint256 i = 0; i < relayerNames.length; i++) {
            bytes memory name = NameCoder.encode(relayerNames[i]);

            relayers[i].owner = _owner(name);

            for (uint256 j = 0; j < subdomains.length; j++) {
                relayers[i].records[j] = _text(NameCoder.addLabel(name, subdomains[j]), URL_KEY);
            }

            if (relayers[i].owner != address(0)) {
                relayers[i].isRegistered = relayerRegistry.isRelayerRegistered(relayers[i].owner, relayers[i].owner);

                relayers[i].balance = relayerRegistry.getRelayerBalance(relayers[i].owner);
            }
        }

        return relayers;
    }

    /// @dev ENSv2 owner first; falls back to the ENSv1 registry
    ///      if v2 reverts or returns zero.
    function _owner(bytes memory name) internal view returns (address owner) {
        try universalHelper.findExactOwner(name) returns (address v2Owner) {
            owner = v2Owner;
        } catch {}

        if (owner == address(0)) {
            bytes32 node = NameCoder.namehash(name, 0);

            try ensRegistry.owner(node) returns (address v1Owner) {
                owner = v1Owner;
            } catch {}
        }
    }

    /// @dev Returns "" when the name has no resolver, no `url` record,
    ///      or resolution reverts, so one bad name never reverts the whole batch.
    function _text(bytes memory name, string memory key) internal view returns (string memory) {
        bytes32 node = NameCoder.namehash(name, 0);

        try universalResolver.resolve(name, abi.encodeCall(ITextResolver.text, (node, key))) returns (
            bytes memory result, address
        ) {
            if (result.length != 0) {
                return abi.decode(result, (string));
            }
        } catch {}

        return "";
    }
}
