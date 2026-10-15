// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// site: https://qubitensor.xyz   x: https://x.com/Qubitensor
//
// QUBITENSOR · TECHNICAL DIRECTIVE TD-06 · IGNITION
//
// 06.1 Role. The launch initializer. Programmable's factory builds every contract, then calls `ignite` once, in the same
//      transaction OWNER signs, with the first buy's ETH attached. Only the factory (DEPLOYER) may call it, and only once.
// 06.2 Sequence. (a) The token learns its hook and Arena (QBT.bind), the hook learns its Arena (bindArena). (b) The pool is
//      created at OPEN_TICK, about one ETH for the whole billion. (c) All 500,000,000 pool QBT go in as one band from
//      MIN_TICK to OPEN_TICK, QBT only, through Uniswap's PositionManager; the position NFT is minted straight to KEEPER
//      (TD-07), which can never withdraw it. (d) The first buy: all the ETH sent buys QBT through QBT.buy, at least
//      `minOut`, and the QBT goes to OWNER; any ETH the pool leaves goes to OWNER too. (e) Rounding dust goes to OWNER.
// 06.3 Afterwards. Nothing stays here: no QBT, no ETH, no owner function. Every deadline is the launch block itself.

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

interface IQBTIgnite {
    function bind(address hook, address arena) external;
    function BINDER() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function buy(uint256 minOut) external payable returns (uint256);
}

interface IHookIgnite {
    function bindArena(address arena) external;
    function poolKey() external view returns (PoolKey memory);
    function OPEN_TICK() external view returns (int24);
    function MIN_TICK() external view returns (int24);
}

interface IPermit2Ignite {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IPositionManagerIgnite {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
}

contract Ignition {
    IPoolManager public constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManagerIgnite public constant POSITION_MANAGER = IPositionManagerIgnite(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IPermit2Ignite public constant PERMIT2 = IPermit2Ignite(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    uint256 internal constant Q96 = 1 << 96;

    address public immutable DEPLOYER;
    address public immutable OWNER;
    address public immutable KEEPER;

    bool public ignited;
    uint256 public bandTokenId;
    uint256 public firstBuyEth;
    uint256 public firstBuyQbt;

    event Ignited(address indexed token, address indexed hook, address indexed arena, uint256 bandTokenId, uint256 liquidity);
    event FirstBuy(uint256 ethIn, uint256 qbtOut, uint256 minOut);

    error NotDeployer();
    error AlreadyIgnited();
    error Miswired();
    error EthTransferFailed();

    constructor(address owner, address keeper) {
        if (owner == address(0) || keeper == address(0)) revert Miswired();
        DEPLOYER = msg.sender;
        OWNER = owner;
        KEEPER = keeper;
    }

    function ignite(IQBTIgnite token, IHookIgnite hook, address arena, uint256 minOut) external payable {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (ignited) revert AlreadyIgnited();
        if (token.BINDER() != address(this)) revert Miswired();
        ignited = true;

        // (a) the wiring
        token.bind(address(hook), arena);
        hook.bindArena(arena);

        // (b) the pool
        PoolKey memory key = hook.poolKey();
        int24 top = hook.OPEN_TICK();
        int24 lo = hook.MIN_TICK();
        uint160 sTop = TickMath.getSqrtPriceAtTick(top);
        POOL_MANAGER.initialize(key, sTop);

        // (c) the band: every pool QBT, QBT only, below the opening price, the NFT to KEEPER
        uint256 supply = token.balanceOf(address(this));
        uint256 liquidity = FullMath.mulDiv(supply, Q96, sTop - TickMath.getSqrtPriceAtTick(lo));
        PERMIT2.approve(address(token), address(POSITION_MANAGER), uint160(supply), uint48(block.timestamp));
        uint256 id = POSITION_MANAGER.nextTokenId();
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, lo, top, liquidity, uint128(0), uint128(supply), KEEPER, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        POSITION_MANAGER.modifyLiquidities(abi.encode(abi.encodePacked(uint8(0x02), uint8(0x0d)), params), block.timestamp);
        bandTokenId = id;
        emit Ignited(address(token), address(hook), arena, id, liquidity);

        // (d) the first buy, for OWNER
        if (msg.value != 0) {
            uint256 got = token.buy{value: msg.value}(minOut);
            firstBuyEth = msg.value - address(this).balance;
            firstBuyQbt = got;
            emit FirstBuy(firstBuyEth, got, minOut);
        }
        // (e) everything left goes to OWNER: the first buy, rounding dust, any ETH the pool left
        uint256 rest = token.balanceOf(address(this));
        if (rest != 0) token.transfer(OWNER, rest);
        if (address(this).balance != 0) {
            (bool ok,) = OWNER.call{value: address(this).balance}("");
            if (!ok) revert EthTransferFailed();
        }
    }

    /// @dev Only the token's refund of ETH the pool could not take, during the first buy.
    receive() external payable {
        if (!ignited) revert Miswired();
    }
}
