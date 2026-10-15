# Qubitensor contracts

Site: https://qubitensor.xyz · X: https://x.com/Qubitensor

Qubitensor ($QBT) is proof of quantum work on Ethereum. Every day the Arena publishes two problems drawn from the chain:
a weighted Max-Cut graph and a 6 to 8 qubit chemistry Hamiltonian. Miners seal answers until 20:00 UTC, reveal them until
midnight, and the contracts score every answer on chain. The best answers share the day's QBT emission and the prize pot.
The token trades in one Uniswap v4 pool, ETH/QBT, whose hook takes the fees below.

This is the source for the Programmable Custom Launch on Ethereum mainnet, compiled with solc 0.8.26+commit.8a97fa7a,
viaIR, optimizer 200 runs, evmVersion cancun, metadata bytecodeHash none. These are exactly the files the seven standard
JSON inputs compile, byte for byte.

## Contracts

| File | Role |
| --- | --- |
| `src/QBT.sol` | The ERC-20. 1,000,000,000 maximum: 500,000,000 go into the pool at the launch, the other 500,000,000 can only be minted by the Arena as mining rewards. `buy` and `sell` trade through the pool. |
| `src/QubitHook.sol` | The pool's hook (flags 0x28CC). Takes the fees, refuses part fills and zero-ETH trades, pays the owner and the prize pot, runs the buyback and burn. No owner functions, no pause, no upgrade. |
| `src/Arena.sol` | The daily rounds: open, seal, reveal, settle, claim, staking and backers. |
| `src/Cut.sol`, `src/Chem.sol` | The scorers: the Max-Cut graph and the chemistry energy, computed on chain. |
| `src/Ignition.sol` | The launch initializer. Called once by Programmable's factory in the launch transaction. |
| `src/VaultKeeper.sol` | Holds the pool's LP NFT forever. Its one function sends the LP fees to the owner. |
| `src/EthereumNativeFeeVaultV3.sol` | Programmable's fee vault, unmodified. The hook deploys it and is its kernel. |

## Fees on every trade

| Fee | Rate | Goes to |
| --- | --- | --- |
| Hook fee | 2% of the trade's ETH | 1% owner, 0.5% the Arena's prize pot, 0.5% buyback and burn of QBT |
| Programmable platform fee | 0.30% of the trade's gross ETH, rounded up | `EthereumNativeFeeVaultV3`, paid only to Programmable's treasury |
| Pool LP fee | 1% | The LP position, collected to the owner through `VaultKeeper` |

There is no launch tax and no warm-up: the first trade pays what every trade pays. The hook's own buyback pays the 0.30%
platform fee too, out of the buyback's share, and spends at most 1% of the pool's ETH depth per block.

## The launch

One transaction, built by Programmable's GraphFactory. It deploys the seven contracts, then calls `Ignition.ignite`, which:

1. binds the token to its hook and Arena, and the hook to its Arena, once;
2. creates the pool at tick 207,240, about 1 ETH for the whole billion;
3. adds all 500,000,000 pool QBT as one band, QBT only, below the opening price, with the LP NFT minted straight to
   `VaultKeeper`;
4. buys 0.02 ETH of QBT for the owner, with a minimum out.

The liquidity can never be withdrawn. No contract has a function that removes it or moves the NFT.

## Measured on a mainnet fork

- The whole launch through Programmable's real GraphFactory `0xB012...A887`, seven targets, `ignite` and the 0.02 ETH
  first buy: 10,831,286 gas. The first buy got 18,618,636 QBT and paid exactly 60,000,000,000,000 wei of platform fee.
- The platform fee is exact to the wei in all four swap kinds (exact input and exact output, buys and sells), at
  0.003, 0.25 and 3 ETH, swapping straight against the PoolManager with no router.
- A swap that names its ETH and is stopped short by its price limit reverts, buying or selling. A trade with no ETH in it
  reverts.
- `VaultKeeper.collectFees` pays the owner the 1% LP fee. The owner cannot transfer the NFT or remove liquidity.

## Owner

`0xA0269d7289b323aB20d5283F1Bbd922891CE61F6` receives the 1% hook fee, the LP fees and the first buy. The owner
has no special powers in any contract.
