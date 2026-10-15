// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// site: https://qubitensor.xyz   x: https://x.com/Qubitensor
//
// QUBITENSOR · TECHNICAL DIRECTIVE TD-01 · THE TOKEN
//
// 01.0 Wiring. Launched in one transaction through Programmable's Custom Launch: this token is built first and knows only
//      the launch initializer (BINDER, TD-06). In the launch the initializer names the hook and the Arena, once
//      (`bind`), and from then on they never change.
// 01.1 Supply. One billion QBT can ever exist. 500,000,000 are struck once, at construction, and handed to the launch
//      initializer; the only start the hook allows puts all of them into the pool's opening band (TD-02). The other 500,000,000 do not
//      exist yet: the Arena strikes them round by round for the solvers who place and the holders backing them, and can
//      never strike past the cap. Nothing and no one else can mint.
// 01.2 Doors. `buy(minOut)` spends every wei sent on QBT in the pool and returns any the pool leaves; `sell(amount,
//      minOut)` sells QBT straight from the caller, no approval, and pays the ETH out. Both refuse to fill below the minimum.
//      The Uniswap app cannot route a pool whose hook settles its levy in deltas: these two functions are the way in and out.
// 01.3 Burn. Any holder can burn their own QBT. The hook burns everything its buybacks purchase. `burned` adds up both.
// 01.4 Powers. There are none: no owner switch, no pause, no list of blocked wallets, no upgrade path.

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

interface IQubitHookKey {
    function poolKey() external view returns (PoolKey memory);
}

contract QBT is ERC20, ReentrancyGuard, IUnlockCallback {
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;
    uint256 public constant POOL_SUPPLY = 500_000_000 ether;
    uint256 public constant MINED_SUPPLY = MAX_SUPPLY - POOL_SUPPLY;

    IPoolManager public immutable poolManager;
    address public immutable OWNER;
    address public immutable BINDER; // the launch initializer: names HOOK and ARENA once
    address public HOOK;
    address public ARENA;

    uint256 public mined; // struck by the Arena to date
    uint256 public burned;

    event BuyFilled(address indexed buyer, uint256 ethIn, uint256 qbtOut);
    event SellFilled(address indexed seller, uint256 qbtIn, uint256 ethOut);

    error NotArena();
    error NotBinder();
    error AlreadyBound();
    error OverCap();
    error NotPoolManager();
    error Slippage();
    error NoQbtOut();
    error ZeroAmount();
    error EthTransferFailed();

    /// @dev The pool supply goes to the launch initializer, which puts all of it into the opening band (TD-06).
    constructor(IPoolManager pm, address owner_, address binder) {
        poolManager = pm;
        OWNER = owner_;
        BINDER = binder;
        _mint(binder, POOL_SUPPLY);
    }

    /// @notice Names the hook and the Arena. Only BINDER, only once, in the launch transaction.
    function bind(address hook, address arena) external {
        if (msg.sender != BINDER) revert NotBinder();
        if (HOOK != address(0)) revert AlreadyBound();
        HOOK = hook;
        ARENA = arena;
    }

    function name() public pure override returns (string memory) {
        return "Qubitensor";
    }

    function symbol() public pure override returns (string memory) {
        return "QBT";
    }

    /// @notice Only the Arena strikes new QBT, and only up to MINED_SUPPLY in total.
    function mint(address to, uint256 amount) external {
        if (msg.sender != ARENA) revert NotArena();
        if (mined + amount > MINED_SUPPLY) revert OverCap();
        mined += amount;
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
        burned += amount;
    }

    // [01.2] DOORS

    uint8 internal constant DOOR_IN = 1;
    uint8 internal constant DOOR_OUT = 2;

    /// @notice Turns the ETH sent into QBT, or reverts if that would be fewer than `minOut`. Of the ETH, 2% is the hook's
    /// levy and 1% the pool's fee.
    function buy(uint256 minOut) external payable nonReentrant returns (uint256 out) {
        if (msg.value == 0) revert ZeroAmount();
        (uint256 spent, uint256 got) = abi.decode(poolManager.unlock(abi.encode(DOOR_IN, msg.sender, msg.value)), (uint256, uint256));
        if (got == 0) revert NoQbtOut();
        if (got < minOut) revert Slippage();
        if (spent < msg.value) _pay(msg.sender, msg.value - spent);
        out = got;
        emit BuyFilled(msg.sender, spent, got);
    }

    /// @notice Sells `amount` of the caller's QBT and pays the ETH to the caller, or reverts below `minOut`. No approval
    /// step: the token moves its own balance.
    function sell(uint256 amount, uint256 minOut) external nonReentrant returns (uint256 ethOut) {
        if (amount == 0) revert ZeroAmount();
        _transfer(msg.sender, address(this), amount);
        uint256 sold;
        (ethOut, sold) = abi.decode(poolManager.unlock(abi.encode(DOOR_OUT, msg.sender, amount)), (uint256, uint256));
        if (ethOut < minOut) revert Slippage();
        emit SellFilled(msg.sender, sold, ethOut);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint8 kind, address who, uint256 amount) = abi.decode(data, (uint8, address, uint256));
        PoolKey memory key = IQubitHookKey(HOOK).poolKey();
        if (kind == DOOR_IN) {
            BalanceDelta d = poolManager.swap(
                key, SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), ""
            );
            uint256 spent = uint256(uint128(-d.amount0()));
            uint256 got = uint256(uint128(d.amount1()));
            if (spent != 0) poolManager.settle{value: spent}();
            if (got != 0) poolManager.take(key.currency1, who, got);
            return abi.encode(spent, got);
        }
        BalanceDelta s = poolManager.swap(
            key, SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}), ""
        );
        uint256 soldNow = uint256(uint128(-s.amount1()));
        if (soldNow != 0) {
            poolManager.sync(key.currency1);
            _transfer(address(this), address(poolManager), soldNow);
            poolManager.settle();
        }
        if (soldNow < amount) _transfer(address(this), who, amount - soldNow); // QBT the pool had no ETH for returns
        uint256 out = uint256(uint128(s.amount0()));
        if (out != 0) poolManager.take(key.currency0, who, out);
        return abi.encode(out, soldNow);
    }

    function _pay(address to, uint256 eth) internal {
        (bool ok,) = to.call{value: eth}("");
        if (!ok) revert EthTransferFailed();
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }
}
