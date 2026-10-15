// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// site: https://qubitensor.xyz   x: https://x.com/Qubitensor
//
// QUBITENSOR · TECHNICAL DIRECTIVE TD-02 · THE POOL
//
// 02.1 The market. Exactly one pool runs through this hook: native ETH against QBT, a 1% LP fee, ticks spaced 60 apart.
//      Any other pairing, fee or spacing is turned away when it is created.
// 02.2 The start. Only the launch initializer (SEEDER, TD-06) creates the pool, in the launch transaction OWNER signs, at a
//      price inside the spacing that begins at tick 207,240: about one ETH for the whole billion. In that same block the
//      hook admits one deposit and no other: a single band from tick -887,220 up to 207,240, QBT only, carrying at least
//      BAND_LIQUIDITY, which is what all 500,000,000 pool QBT add up to there. Until it lands nobody can trade. The position
//      NFT goes straight to the locker (TD-07), which can only ever pay its LP fees to OWNER: the liquidity is locked for good.
// 02.3 The levy. 2% (FEE) of the ETH leg of each trade, from the very first trade on: no launch surcharge, no taper. It is
//      cut from the ETH a trader names before the swap runs, and from the ETH that comes out of the swap otherwise. One
//      half is OWNER's, one quarter feeds the Arena's prize pool, one quarter waits to buy QBT back and burn it. The pool's
//      own 1% belongs to the position NFT. The hook's buybacks are not levied. In econ/econ_qbt.js OWNER's half and the
//      pool's 1% together come to about 2 ETH a year at a quiet launch and about 20 at the largest launch on record.
// 02.3a The platform fee. Every swap also pays PLATFORM_FEE (0.30%) of its gross native value to Programmable, once, with
//      the accounting of Programmable's EthereumNative30HookV3: gross is the ETH that crosses including every fee here (a
//      net amount is grossed up), the fee is ceil(gross x 0.30%) and is set aside first. It is minted as ETH claims to
//      feeVault, an unmodified EthereumNativeFeeVaultV3 this hook deploys in its constructor, and recorded there; anyone
//      may call feeVault.claimPlatform(), which pays 0xD885...79da and no one else. The hook's own buybacks, which the
//      PoolManager never routes through these callbacks, pay it too, from the burn quarter, on the same gross.
// 02.3b Whole fills only. When a trader names the ETH amount, the fees are cut before the swap runs on the whole amount,
//      so the swap must fill whole: a partial fill (a price limit reached first) reverts, as in the canonical kernel. A
//      swap that moves no ETH or no QBT reverts too.
// 02.4 Paying out. Three calls anyone may make, each paying only where it says: `sendOwnerFee` to OWNER, `fundPrizes` to
//      the Arena's prize pool, `buyback` into QBT that is then burned. A buyback spends at most BUYBACK_CAP_BPS (1%) of the
//      ETH the pool holds in reserve at its current price, and only once per block: nudging the price by about 1% against
//      3% in fees each way leaves nothing for anyone who brackets it with trades of their own (review/REVIEW.md measured a
//      bracketing trader 2.05e14 wei down).
// 02.5 Powers. The hook has no owner functions, no pause and no upgrade. Its settings are constants.

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {QBT} from "./QBT.sol";
import {EthereumNativeFeeVaultV3} from "./EthereumNativeFeeVaultV3.sol";

interface IArenaPrize {
    function prize() external payable;
}

contract QubitHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 public constant LP_FEE = 10_000;
    int24 public constant SPACING = 60;
    int24 public constant OPEN_TICK = 207_240; // 1.0001^207,240 QBT to the ETH: the whole billion costs ~1.0003 ETH
    int24 public constant MIN_TICK = -887_220; // the band's floor: the lowest multiple of 60 a tick may take
    uint256 public constant PIPS = 1_000_000;
    uint256 public constant FEE = 20_000; // in PIPS: 2% of each trade's ETH leg
    uint256 public constant PLATFORM_FEE = 3_000; // in PIPS: 0.30% of each swap's gross native value, to Programmable
    uint256 public constant BUYBACK_CAP_BPS = 100;
    uint256 internal constant Q96 = 1 << 96;

    uint8 internal constant PAY_OWNER = 1;
    uint8 internal constant PAY_PRIZES = 2;
    uint8 internal constant BUY_BURN = 3;

    IPoolManager public immutable poolManager;
    address public immutable OWNER;
    address public immutable TOKEN;
    address public immutable SEEDER; // the launch initializer: creates the pool, names the Arena once
    uint128 public immutable BAND_LIQUIDITY;
    address public ARENA;
    EthereumNativeFeeVaultV3 public feeVault; // holds and pays the platform fee; set once, in the constructor

    PoolId public poolId;
    bool public opened;
    bool public bandIn; // the starting band has landed: trading may begin
    uint40 public openedAt;

    // the hook's ETH, held in the PoolManager as ERC-6909 claims (id 0), split by where it is going
    uint256 public ownerShare;
    uint256 public prizeShare;
    uint256 public burnShare;
    uint256 public feeTotal; // the levy, all of it, since the start
    uint256 public platformTotal; // the platform fee recorded in feeVault, all of it, since the start
    uint256 public buybackEth;
    uint256 public buybackBurned;
    uint64 public lastBuybackBlock;

    event MarketOpened(PoolId indexed id, uint160 sqrtPriceX96);
    event BandIn(uint256 liquidity);
    event Levied(address indexed trader, bool buy, uint256 eth, uint256 fee);
    event OwnerFeeSent(uint256 eth);
    event PrizesFunded(uint256 eth);
    event BoughtBack(uint256 eth, uint256 burned);
    event PlatformFee(uint256 gross, uint256 fee);

    error NotPoolManager();
    error NotOwner();
    error ForeignPool();
    error NotOpeningPrice();
    error AlreadyOpened();
    error NoBandYet();
    error NotTheOpeningBand();
    error NothingOwed();
    error OneBuybackPerBlock();
    error HookNotImplemented();
    error NotSeeder();
    error AlreadyBound();
    error PartialFill(uint256 expected, uint256 actual);
    error NoTrade();

    constructor(IPoolManager pm, address owner, address token, address seeder) {
        poolManager = pm;
        OWNER = owner;
        TOKEN = token;
        SEEDER = seeder;
        feeVault = new EthereumNativeFeeVaultV3(pm, owner);
        BAND_LIQUIDITY = uint128(
            FullMath.mulDiv(500_000_000 ether, Q96, TickMath.getSqrtPriceAtTick(OPEN_TICK) - TickMath.getSqrtPriceAtTick(MIN_TICK))
        );
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice ETH against QBT at 1%, spacing 60, through this hook: the only key it lets the PoolManager create.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(TOKEN), LP_FEE, SPACING, IHooks(address(this)));
    }

    /// @notice Names the Arena (where the prize quarter goes). Only SEEDER, only once, in the launch transaction.
    function bindArena(address arena) external {
        if (msg.sender != SEEDER) revert NotSeeder();
        if (ARENA != address(0)) revert AlreadyBound();
        ARENA = arena;
    }

    // [02.2] THE START

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external onlyPoolManager returns (bytes4) {
        if (sender != SEEDER) revert NotSeeder();
        if (opened) revert AlreadyOpened();
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != TOKEN || key.fee != LP_FEE
                || key.tickSpacing != SPACING || address(key.hooks) != address(this)
        ) revert ForeignPool();
        int24 t = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        if (t < OPEN_TICK || t >= OPEN_TICK + SPACING) revert NotOpeningPrice();
        opened = true;
        openedAt = uint40(block.timestamp);
        poolId = key.toId();
        emit MarketOpened(poolId, sqrtPriceX96);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Before the starting band lands, the one deposit admitted is the launch initializer's, in the same transaction
    /// that created the pool (SEEDER creates the pool and adds the band in one call, so nothing can come between), spanning
    /// MIN_TICK to OPEN_TICK with BAND_LIQUIDITY or more. Once it has landed, deposits are open to everyone.
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata p, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (!bandIn) {
            if (block.timestamp != openedAt) revert NotOwner();
            if (p.tickLower != MIN_TICK || p.tickUpper != OPEN_TICK || p.liquidityDelta < int256(uint256(BAND_LIQUIDITY))) {
                revert NotTheOpeningBand();
            }
            bandIn = true;
            emit BandIn(uint256(p.liquidityDelta));
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    // [02.3] THE LEVY, ON EVERY TRADE

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata p, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (sender == address(this)) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        if (!bandIn) revert NoBandYet();
        // the trader names an ETH amount in two cases: paying in a set amount of ETH, or asking for a set amount out
        if ((p.amountSpecified < 0) != p.zeroForOne) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        uint256 amt = p.amountSpecified < 0 ? uint256(-p.amountSpecified) : uint256(p.amountSpecified);
        uint256 fee = _take(amt, p.zeroForOne, p.amountSpecified > 0);
        // [02.3b] the swap must move exactly this much ETH, or afterSwap reverts
        uint256 expect = p.amountSpecified < 0 ? amt - fee : amt + fee;
        assembly ("memory-safe") {
            tstore(0x51b7, expect)
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function afterSwap(address sender, PoolKey calldata, SwapParams calldata p, BalanceDelta d, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (sender == address(this)) return (IHooks.afterSwap.selector, 0);
        int128 e = d.amount0();
        uint256 eth = e < 0 ? uint256(int256(-e)) : uint256(int256(e));
        if (eth == 0 || d.amount1() == 0) revert NoTrade();
        if ((p.amountSpecified < 0) == p.zeroForOne) {
            uint256 expect;
            assembly ("memory-safe") {
                expect := tload(0x51b7)
            }
            if (eth != expect) revert PartialFill(expect, eth);
            return (IHooks.afterSwap.selector, 0);
        }
        // otherwise ETH is whatever the swap worked out: a set amount of QBT sold, or a set amount of QBT bought
        return (IHooks.afterSwap.selector, int128(int256(_take(eth, p.zeroForOne, p.amountSpecified > 0))));
    }

    /// @dev Levy FEE and PLATFORM_FEE on the same gross native value [02.3a]: `eth` is gross (exact input) or net of every
    /// fee (`net`, exact output, grossed up and rounded up). The platform fee, ceil(gross x 0.30%), is set aside first and
    /// minted to feeVault; the levy stays here as ETH claims, split OWNER half, prizes a quarter, the burn whatever is left
    /// (so rounding never strays outside the three). Returns everything taken from the swap.
    function _take(uint256 eth, bool isBuy, bool net) internal returns (uint256 total) {
        uint256 gross = net ? FullMath.mulDivRoundingUp(eth, PIPS, PIPS - FEE - PLATFORM_FEE) : eth;
        uint256 pf = FullMath.mulDivRoundingUp(gross, PLATFORM_FEE, PIPS);
        uint256 fee = net ? gross - eth - pf : (gross * FEE) / PIPS;
        total = fee + pf;
        if (fee != 0) {
            uint256 ownerPart = fee / 2;
            uint256 prizePart = fee / 4;
            ownerShare += ownerPart;
            prizeShare += prizePart;
            burnShare += fee - ownerPart - prizePart;
            feeTotal += fee;
            poolManager.mint(address(this), 0, fee);
            emit Levied(tx.origin, isBuy, gross, fee);
        }
        if (pf != 0) {
            poolManager.mint(address(feeVault), 0, pf);
            _platform(gross, pf);
        }
    }

    /// @dev Records `pf` wei of platform fee that feeVault already holds as ETH claims.
    function _platform(uint256 gross, uint256 pf) internal {
        platformTotal += pf;
        feeVault.recordFees(pf, 0);
        emit PlatformFee(gross, pf);
    }

    // [02.4] PAYING OUT

    /// @notice Sends OWNER everything owed to them so far. Callable by anyone; the ETH goes to OWNER and nowhere else.
    function sendOwnerFee() external {
        if (ownerShare == 0) revert NothingOwed();
        uint256 amt = ownerShare;
        poolManager.unlock(abi.encode(PAY_OWNER, amt));
        emit OwnerFeeSent(amt);
    }

    /// @notice Hands the prize quarter to the Arena. Callable by anyone, and the Arena calls it itself whenever it
    /// settles a round. Returns what moved (zero when nothing was waiting).
    function fundPrizes() external returns (uint256 amt) {
        amt = prizeShare;
        if (amt == 0) return 0;
        poolManager.unlock(abi.encode(PAY_PRIZES, amt));
        emit PrizesFunded(amt);
    }

    /// @notice Spends the burn quarter on QBT and burns what it buys: no more than 1% of the pool's ETH reserve per call,
    /// and one call per block.
    function buyback() external returns (uint256 spent, uint256 burnedNow) {
        if (!bandIn || burnShare == 0) revert NothingOwed();
        if (lastBuybackBlock == block.number) revert OneBuybackPerBlock();
        lastBuybackBlock = uint64(block.number);
        uint256 cap = (reserveEth() * BUYBACK_CAP_BPS) / 10_000;
        uint256 room = (burnShare * (PIPS - PLATFORM_FEE)) / PIPS; // the platform fee on the buyback comes out of the same quarter
        room = room > 2 ? room - 2 : 0; // it rounds up: two wei of room
        uint256 amt = room < cap ? room : cap;
        if (amt == 0) revert NothingOwed();
        (spent, burnedNow) = abi.decode(poolManager.unlock(abi.encode(BUY_BURN, amt)), (uint256, uint256));
        emit BoughtBack(spent, burnedNow);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (uint8 op, uint256 amt) = abi.decode(data, (uint8, uint256));
        if (op == PAY_OWNER) {
            ownerShare -= amt;
            poolManager.burn(address(this), 0, amt);
            poolManager.take(Currency.wrap(address(0)), OWNER, amt);
            return "";
        }
        if (op == PAY_PRIZES) {
            prizeShare -= amt;
            poolManager.burn(address(this), 0, amt);
            poolManager.take(Currency.wrap(address(0)), address(this), amt);
            IArenaPrize(ARENA).prize{value: amt}();
            return "";
        }
        // BUY_BURN: give up `amt` of claims, buy with it, re-mint whatever the pool left unspent, burn the QBT
        poolManager.burn(address(this), 0, amt);
        BalanceDelta d = poolManager.swap(
            poolKey(), SwapParams({zeroForOne: true, amountSpecified: -int256(amt), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), ""
        );
        uint256 spent = uint256(int256(-d.amount0()));
        uint256 got = uint256(int256(d.amount1()));
        if (spent < amt) poolManager.mint(address(this), 0, amt - spent);
        // [02.3a] the buyback's own platform fee: gross = spent + pf with pf = ceil(gross x 0.30%), the fixed point of that
        // equation (reached in at most two steps from below), paid from the burn quarter's claims
        uint256 pf = FullMath.mulDivRoundingUp(spent, PLATFORM_FEE, PIPS - PLATFORM_FEE);
        for (uint256 i; i < 3; ++i) {
            uint256 next = FullMath.mulDivRoundingUp(spent + pf, PLATFORM_FEE, PIPS);
            if (next == pf) break;
            pf = next;
        }
        if (pf != 0) {
            poolManager.transfer(address(feeVault), 0, pf);
            _platform(spent + pf, pf);
        }
        burnShare -= spent + pf;
        buybackEth += spent;
        if (got != 0) {
            poolManager.take(Currency.wrap(TOKEN), address(this), got);
            QBT(payable(TOKEN)).burn(got);
            buybackBurned += got;
        }
        return abi.encode(spent, got);
    }

    /// @notice How much ETH the pool's in-range liquidity stands for at today's price, L divided by the square root of the
    /// price. Zero until the first trade moves the price into the band.
    function reserveEth() public view returns (uint256) {
        if (!opened) return 0;
        (uint160 s,,,) = poolManager.getSlot0(poolId);
        uint128 l = poolManager.getLiquidity(poolId);
        return FullMath.mulDiv(uint256(l), Q96, s);
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    // CALLBACKS THIS HOOK NEVER ASKS FOR (its address does not carry their flags, so the PoolManager never calls them)

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
