// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// site: https://qubitensor.xyz   x: https://x.com/Qubitensor
//
// QUBITENSOR · TECHNICAL DIRECTIVE TD-07 · THE VAULT KEEPER
//
// 07.1 Custody. The pool's opening position NFT is minted straight here in the launch transaction (TD-06) and stays here for
//      good. That is the liquidity lock.
// 07.2 One function. `collectFees(tokenId)`: anyone may call it. It removes zero liquidity from a position held here and
//      sends the LP fees it has earned, ETH and QBT, to OWNER. Only fees ever leave.
// 07.3 What cannot happen, because the code for it does not exist: withdrawing liquidity, moving or approving the NFT,
//      an arbitrary call, an owner function, an upgrade.

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface IPositionManagerKeeper {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256);
}

contract VaultKeeper {
    IPositionManagerKeeper public constant POSITION_MANAGER = IPositionManagerKeeper(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    address public immutable OWNER;

    event FeesCollected(uint256 indexed tokenId);

    error ZeroOwner();

    constructor(address owner) {
        if (owner == address(0)) revert ZeroOwner();
        OWNER = owner;
    }

    /// @notice Pays the LP fees of `tokenId` (held here) to OWNER: DECREASE_LIQUIDITY of zero, then TAKE_PAIR to OWNER.
    function collectFees(uint256 tokenId) external {
        (PoolKey memory key,) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, OWNER);
        POSITION_MANAGER.modifyLiquidities(abi.encode(abi.encodePacked(uint8(0x01), uint8(0x11)), params), block.timestamp);
        emit FeesCollected(tokenId);
    }
}
