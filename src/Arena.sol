// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// QUBITENSOR · TECHNICAL DIRECTIVE TD-03 · THE RACE
//
// 03.1 Calendar. A round is one UTC day (block time / 86,400). Its two problems exist once somebody calls `open` that day,
//      before 20:00 UTC; the seed is keccak(prevrandao, round, this contract), the Max-Cut graph comes from keccak(seed, 0)
//      and the chemistry magnet from keccak(seed, 1). Answers are sealed until 20:00 UTC (SEAL_TIME), revealed until
//      midnight, and anybody settles the round after that. `open` waits for the pool (TD-02): the first round ever opened
//      is round zero of the emission schedule.
// 03.2 Seal. `seal(subnet, hash)` with a DEPOSIT of 0.0003 ETH, where hash = keccak(abi.encode(round, subnet, solver,
//      keccak(answer), salt)). Nothing in a seal shows the answer, and seals are filed per solver, so a hash copied out of
//      the mempool blocks nobody. Revealing returns the deposit whatever the score (held for `claim` if the solver's
//      address refuses ETH); a seal never revealed leaves its deposit to the prize pool.
// 03.3 Reveal. The Arena scores the answer exactly (TD-04, TD-05) and keeps three places per subnet, higher score first,
//      the lower seal number first on equal scores. An answer places once per round: its oldest seal holds the place,
//      whatever order the reveals come in, so nobody gains by racing to reveal. Max-Cut counts only from 85% of the
//      graph's total weight; chemistry only below the lowest energy any single bit-string reaches.
// 03.4 Results. Rounds settle oldest first, `settle(n)` up to n of them and never more than SETTLE_MAX (12). A round pays
//      PAYOUT_BPS (20%) of the prize pool, half per subnet, and strikes the round's emission, half per subnet, both split
//      70% / 20% / 10% over the three places. A place nobody earned pays nothing and strikes nothing, now or later.
//      Measured in test/Gas.t.sol: a round with six new winners, each with stake behind it, costs about 0.83M gas to
//      settle, so a full call of twelve came to 9,982,098, well under the 16,777,216 a transaction may use.
// 03.5 Emission. 250,000,000 QBT over the first 365 rounds, then half as much per round every further 365.
// 03.6 Backers. Anyone may stake QBT behind a solver. Stake placed during round r takes part from round r + 1, so nothing
//      staked once the answers are known can share in them. Each solver chooses the slice of its winnings that goes to
//      its backers, 0% to 20%; a change first settles every earlier round, then applies from the next round on. Stake adds
//      up to BOOST_MAX_BPS (20%) to a solver's place weight, in full at 10,000,000 QBT, and never lifts it past the place
//      ahead. Stake comes back whenever asked, settled or not; stake withdrawn before a round settles takes no part in it.
//      Backers' shares round down, and products run at 512 bits, so even a one-wei stake cannot push the running totals
//      out of range for anyone else. Measured: after a long run with odd amounts, 4 wei of QBT and 2 wei of ETH stayed.
// 03.7 Difficulty. Max-Cut: a tie between the two best answers grows the next graph by 25% (up to 4,096 nodes); three
//      rounds in a row with nothing at 85% shrink it by 20% (down to 128). Chemistry: every 30 rounds that produce a
//      counted answer add one qubit, from 6 up to 8.
// 03.8 Limits, plainly. The chain cannot tell a quantum computer from a laptop: the solver label is the solver's own word.
//      A solver may enter several different answers, and they only push others down where they score higher than every
//      one of those others' own answers. Whoever lands `open` decides which block's prevrandao seeds the day; that buys no
//      head start, since everyone gets the same problems for up to twenty hours (review/REVIEW.md, finding 2).
// 03.9 Powers. None: no administrator, no pause, no upgrade, no adjustable setting.

import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

interface ICut {
    function score(bytes32 seed, uint256 n, bytes calldata side) external pure returns (uint256 cut, uint256 total);
}

interface IChem {
    function score(bytes32 seed, uint256 q, bytes calldata angles) external pure returns (int256 energy, int256 par);
}

interface IQBTMint {
    function mint(address to, uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IHookArena {
    function opened() external view returns (bool);
    function fundPrizes() external returns (uint256);
}

contract Arena is ReentrancyGuard {
    uint256 public constant DAY = 1 days;
    uint256 public constant SEAL_TIME = 20 hours;
    uint256 public constant DEPOSIT = 0.0003 ether;
    uint256 public constant PAYOUT_BPS = 2_000;
    uint256 public constant YEAR_ROUNDS = 365;
    uint256 public constant FIRST_YEAR = 250_000_000 ether;
    uint256 public constant BOOST_MAX_BPS = 2_000;
    uint256 public constant STAKE_FULL = 10_000_000 ether;
    uint256 public constant BACKER_MAX_BPS = 2_000;
    uint256 public constant PAR_BPS = 8_500; // the Max-Cut bar: 85% of the graph's total weight
    uint256 public constant MIN_NODES = 128;
    uint256 public constant MAX_NODES = 4_096;
    uint256 public constant MIN_QUBITS = 6;
    uint256 public constant MAX_QUBITS = 8;
    uint256 public constant QUBIT_STEP = 30;
    uint256 public constant SETTLE_MAX = 12; // rounds per settle call: twelve of the costliest kind measured 9,982,098 gas
    uint256 public constant SELF_SETTLE_MAX = 2; // rounds stake and setBackerShare clear themselves before asking for settle
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ACC = 1e36;

    uint8 public constant MAXCUT = 0;
    uint8 public constant CHEM = 1;

    ICut public immutable CUT;
    IChem public immutable CHEMISTRY;
    IQBTMint public immutable QBT;
    IHookArena public immutable HOOK;

    struct Round {
        bytes32 seed;
        uint32 nodes;
        uint8 qubits;
        bool settled;
        uint64 seals;
        uint128 depositsOut; // deposits still riding on unrevealed seals
    }

    struct Placing {
        address miner;
        uint64 seq; // the seal's number: the lower one wins a tie
        int256 score; // Max-Cut: weight cut; chemistry: the energy with its sign flipped, so higher is better on both
    }

    struct Seal {
        uint32 round;
        uint8 subnet;
        uint64 seq; // zero means no seal was filed under this hash
        bool shown;
    }

    struct Miner {
        uint256 active; // stake taking part now
        uint256 waiting; // stake placed in waitingRound, taking part once that round has settled
        uint32 waitingRound;
        uint16 backerBps;
        uint16 nextBackerBps;
        uint32 backerFrom;
        uint256 perUnitEth; // running total earned per unit of active stake, scaled by 1e36
        uint256 perUnitQbt;
    }

    struct Activation {
        uint256 perUnitEth; // the solver's running totals at the moment that round's stake started taking part
        uint256 perUnitQbt;
    }

    struct Position {
        uint256 amount; // taking part
        uint256 queued; // placed in round waitingSince, not taking part yet
        uint32 waitingSince;
        uint256 snapEth; // the solver's running totals when `amount` was last settled up
        uint256 snapQbt;
    }

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(uint256 => Placing[3])) internal _top;
    mapping(address => mapping(bytes32 => Seal)) public seals; // solver => seal hash
    mapping(uint256 => mapping(bytes32 => uint64)) public firstSeal; // round => keccak(subnet, answer) => lowest seal number shown
    mapping(address => Miner) public miners;
    mapping(address => mapping(uint256 => Activation)) public activations;
    mapping(address => mapping(address => Position)) public positions; // backer => solver => position

    uint256 public firstOpen; // one past the first round ever opened; zero until then
    uint256 public lastSettled; // the next round due to settle (all before it are done)
    uint256 public pot; // prize pool, in ETH
    uint64 public sealCount;
    uint32 public nodes = 256;
    uint8 public qubits = uint8(MIN_QUBITS);
    uint16 public cutDryRounds;
    uint16 public chemLiveRounds;

    mapping(address => uint256) public dueEth; // ETH waiting for its owner to withdraw it
    mapping(address => uint256) public dueQbt; // backers' QBT waiting to be withdrawn

    event Opened(uint256 indexed round, bytes32 seed, uint256 nodes, uint256 qubits);
    event Sealed(uint256 indexed round, uint8 indexed subnet, address indexed miner, bytes32 hash, uint64 seq);
    event ReadOut(uint256 indexed round, uint8 indexed subnet, address indexed miner, int256 score, bool eligible, bool duplicate, uint8 rank, uint8 solver);
    event Rewarded(uint256 indexed round, uint8 indexed subnet, address indexed miner, uint8 rank, uint256 eth, uint256 qbt, uint256 toStakersEth, uint256 toStakersQbt);
    event Settled(uint256 indexed round, uint256 paidEth, uint256 mintedQbt, uint256 pot, uint256 nextNodes, uint256 nextQubits);
    event Prize(uint256 eth);
    event Staked(address indexed staker, address indexed miner, uint256 amount, uint256 fromRound);
    event Unstaked(address indexed staker, address indexed miner, uint256 amount);
    event BackerShareSet(address indexed miner, uint256 bps, uint256 fromRound);
    event PrizeWithdrawn(address indexed who, uint256 eth);
    event StakeEarningsWithdrawn(address indexed staker, address indexed miner, uint256 eth, uint256 qbt);

    error PoolNotOpen();
    error AlreadyOpen();
    error NotOpen();
    error SealClosed();
    error RevealClosed();
    error WrongDeposit();
    error SealTaken();
    error NoSuchSeal();
    error BadSubnet();
    error RoundsWaiting();
    error AmountOutOfRange();
    error BackerShareTooHigh();
    error NothingOwed();
    error NotHook();
    error EthTransferFailed();

    constructor(ICut cut, IChem chem, IQBTMint qbt, IHookArena hook) {
        CUT = cut;
        CHEMISTRY = chem;
        QBT = qbt;
        HOOK = hook;
    }

    // [03.1] CALENDAR

    function currentRound() public view returns (uint256) {
        return block.timestamp / DAY;
    }

    /// @notice The most QBT a round can strike, both subnets with every place filled: 250,000,000 / 365 in the first 365
    /// rounds, half that in the next 365, and so on.
    function emissionOf(uint256 round) public view returns (uint256) {
        if (firstOpen == 0 || round + 1 < firstOpen) return 0;
        uint256 year = (round + 1 - firstOpen) / YEAR_ROUNDS;
        if (year >= 64) return 0;
        return (FIRST_YEAR / YEAR_ROUNDS) >> year;
    }

    /// @notice Everything a solver needs: the graph's seed and node count, the magnet's seed and qubit count. Zeros until opened.
    function problems(uint256 round) external view returns (bytes32 cutSeed, uint256 n, bytes32 chemSeed, uint256 q) {
        Round storage R = rounds[round];
        if (R.seed == 0) return (0, 0, 0, 0);
        return (keccak256(abi.encode(R.seed, 0)), R.nodes, keccak256(abi.encode(R.seed, 1)), R.qubits);
    }

    function top(uint256 round, uint256 subnet) external view returns (Placing[3] memory) {
        return _top[round][subnet];
    }

    // [03.2] SEAL AND [03.3] REVEAL

    /// @notice Draws today's two problems. Open to anyone, once per round, any time before 20:00 UTC.
    function open() external {
        if (!HOOK.opened()) revert PoolNotOpen();
        uint256 r = currentRound();
        Round storage R = rounds[r];
        if (R.seed != 0) revert AlreadyOpen();
        if (block.timestamp >= r * DAY + SEAL_TIME) revert SealClosed();
        if (firstOpen == 0) {
            firstOpen = r + 1;
            lastSettled = r; // rounds before the first are never settled: settling starts at r
        }
        R.seed = keccak256(abi.encode(block.prevrandao, r, address(this)));
        R.nodes = nodes;
        R.qubits = qubits;
        emit Opened(r, R.seed, R.nodes, R.qubits);
    }

    function seal(uint8 subnet, bytes32 hash) external payable {
        if (subnet > CHEM) revert BadSubnet();
        if (msg.value != DEPOSIT) revert WrongDeposit();
        uint256 r = currentRound();
        Round storage R = rounds[r];
        if (R.seed == 0) revert NotOpen();
        if (block.timestamp >= r * DAY + SEAL_TIME) revert SealClosed();
        Seal storage S = seals[msg.sender][hash];
        if (S.seq != 0) revert SealTaken();
        uint64 seq = ++sealCount;
        (S.round, S.subnet, S.seq) = (uint32(r), subnet, seq);
        R.seals += 1;
        R.depositsOut += uint128(DEPOSIT);
        emit Sealed(r, subnet, msg.sender, hash, seq);
    }

    /// @notice The hash a solver files with `seal` for this answer and salt.
    function sealHash(uint256 round, uint8 subnet, address miner, bytes calldata answer, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(round, subnet, miner, keccak256(answer), salt));
    }

    /// @notice Shows a sealed answer, from 20:00 UTC to midnight of the round it was sealed in, and scores it. `solver` is
    /// the solver's own description (0 classical, 1 quantum hardware, 2 quantum simulator, 3 AI, 4 hybrid), unchecked.
    function reveal(uint8 subnet, bytes calldata answer, bytes32 salt, uint8 solver) external nonReentrant returns (int256 score, bool eligible) {
        uint256 r = currentRound();
        if (block.timestamp < r * DAY + SEAL_TIME) revert RevealClosed();
        Seal storage S = seals[msg.sender][sealHash(r, subnet, msg.sender, answer, salt)];
        if (S.seq == 0 || S.round != r || S.subnet != subnet || S.shown) revert NoSuchSeal();
        S.shown = true;
        Round storage R = rounds[r];
        R.depositsOut -= uint128(DEPOSIT);
        if (subnet == MAXCUT) {
            (uint256 cut, uint256 total) = CUT.score(keccak256(abi.encode(R.seed, 0)), R.nodes, answer);
            score = int256(cut);
            eligible = cut * BPS >= total * PAR_BPS;
        } else {
            (int256 energy, int256 par) = CHEMISTRY.score(keccak256(abi.encode(R.seed, 1)), R.qubits, answer);
            score = -energy;
            eligible = energy < par;
        }
        bool duplicate;
        uint8 rank;
        if (eligible) {
            bytes32 key = keccak256(abi.encode(subnet, answer));
            uint64 held = firstSeal[r][key];
            if (held != 0 && held < S.seq) {
                duplicate = true; // a lower seal number already holds this exact answer
            } else {
                firstSeal[r][key] = S.seq;
                if (held != 0) _unrank(_top[r][subnet], held); // this seal is older: the newer copy leaves the board
                rank = _rank(_top[r][subnet], Placing(msg.sender, S.seq, score));
            }
        }
        // deposit back now, or kept for `claim` if the solver's address refuses ETH: no reveal can fail on the refund
        (bool sent,) = msg.sender.call{value: DEPOSIT}("");
        if (!sent) dueEth[msg.sender] += DEPOSIT;
        emit ReadOut(r, subnet, msg.sender, score, eligible, duplicate, rank, solver);
    }

    /// @dev Removes the placing filed under seal number `seq`, closing the gap; nothing happens if it is not on the board.
    function _unrank(Placing[3] storage t, uint64 seq) internal {
        for (uint256 i; i < 3; ++i) {
            if (t[i].miner == address(0)) return;
            if (t[i].seq == seq) {
                for (uint256 k = i; k < 2; ++k) t[k] = t[k + 1];
                delete t[2];
                return;
            }
        }
    }

    /// @dev Puts `e` among the three places (higher score first, lower seal number on a tie). Returns its place 1 to 3, or 0.
    function _rank(Placing[3] storage t, Placing memory e) internal returns (uint8) {
        uint256 i = 3;
        while (i > 0) {
            Placing storage above = t[i - 1];
            if (above.miner != address(0) && (above.score > e.score || (above.score == e.score && above.seq < e.seq))) break;
            --i;
        }
        if (i == 3) return 0;
        for (uint256 k = 2; k > i; --k) t[k] = t[k - 1];
        t[i] = e;
        return uint8(i + 1);
    }

    // [03.4] RESULTS

    /// @notice Settles finished rounds oldest first, `maxRounds` at most and never more than SETTLE_MAX. Open to anyone.
    /// The costliest round measured about 0.83M gas, so settling one round at a time always fits in a transaction.
    function settle(uint256 maxRounds) external nonReentrant returns (uint256 done) {
        done = _settleUpTo(maxRounds < SETTLE_MAX ? maxRounds : SETTLE_MAX);
    }

    function _settleUpTo(uint256 maxRounds) internal returns (uint256 done) {
        uint256 now_ = currentRound();
        while (firstOpen != 0 && lastSettled < now_ && done < maxRounds) {
            _settle(lastSettled);
            ++lastSettled;
            ++done;
        }
    }

    function _settle(uint256 r) internal {
        Round storage R = rounds[r];
        R.settled = true;
        if (R.seed == 0) {
            emit Settled(r, 0, 0, pot, nodes, qubits);
            return;
        }
        HOOK.fundPrizes(); // pulls the hook's waiting prize quarter in, through `prize`
        pot += R.depositsOut; // deposits of seals nobody revealed
        R.depositsOut = 0;
        uint256 payout = (pot * PAYOUT_BPS) / BPS;
        uint256 emission = emissionOf(r);
        uint256 paid;
        uint256 minted;
        for (uint256 s; s < 2; ++s) {
            (uint256 p, uint256 m) = _payRanks(r, s, payout / 2, emission / 2);
            paid += p;
            minted += m;
        }
        pot -= paid;
        _difficulty(r);
        emit Settled(r, paid, minted, pot, nodes, qubits);
    }

    function _payRanks(uint256 r, uint256 subnet, uint256 eth, uint256 qbt) internal returns (uint256 paid, uint256 minted) {
        Placing[3] storage t = _top[r][subnet];
        uint256[3] memory w;
        uint256 sum;
        uint256 prev = type(uint256).max;
        for (uint256 i; i < 3; ++i) {
            address m = t[i].miner;
            if (m == address(0)) break;
            Miner storage M = miners[m];
            _admitWaiting(m, M, r);
            uint256 base = i == 0 ? 7_000 : i == 1 ? 2_000 : 1_000;
            uint256 boost = (BOOST_MAX_BPS * FixedPointMathLib.min(M.active, STAKE_FULL)) / STAKE_FULL;
            uint256 wi = (base * (BPS + boost)) / BPS;
            if (wi > prev) wi = prev; // stake never lifts a place above the one ahead of it
            w[i] = wi;
            prev = wi;
            sum += wi;
        }
        uint256 d = sum > BPS ? sum : BPS;
        for (uint256 i; i < 3; ++i) {
            if (w[i] == 0) break;
            address m = t[i].miner;
            uint256 e = (eth * w[i]) / d;
            uint256 q = (qbt * w[i]) / d;
            (uint256 se, uint256 sq) = _shareOut(m, r, e, q);
            dueEth[m] += e - se;
            if (q - sq != 0) QBT.mint(m, q - sq);
            if (sq != 0) QBT.mint(address(this), sq);
            paid += e;
            minted += q;
            emit Rewarded(r, uint8(subnet), m, uint8(i + 1), e - se, q - sq, se, sq);
        }
    }

    /// @dev Carves the backers' share out of a solver's prize and spreads it over the stake taking part. Returns the share.
    function _shareOut(address m, uint256 r, uint256 eth, uint256 qbt) internal returns (uint256 se, uint256 sq) {
        Miner storage M = miners[m];
        if (M.active == 0) return (0, 0);
        uint256 bps = r >= M.backerFrom ? M.nextBackerBps : M.backerBps;
        if (bps == 0) return (0, 0);
        se = (eth * bps) / BPS;
        sq = (qbt * bps) / BPS;
        M.perUnitEth += (se * ACC) / M.active;
        M.perUnitQbt += (sq * ACC) / M.active;
    }

    function _difficulty(uint256 r) internal {
        Placing[3] storage c = _top[r][MAXCUT];
        if (c[0].miner == address(0)) {
            if (++cutDryRounds >= 3) {
                cutDryRounds = 0;
                uint256 smaller = ((uint256(nodes) * 8) / 10 / 64) * 64;
                nodes = uint32(smaller < MIN_NODES ? MIN_NODES : smaller);
            }
        } else {
            cutDryRounds = 0;
            if (c[1].miner != address(0) && c[1].score == c[0].score) {
                uint256 bigger = ((uint256(nodes) * 125) / 100 + 63) / 64 * 64;
                nodes = uint32(bigger > MAX_NODES ? MAX_NODES : bigger);
            }
        }
        if (_top[r][CHEM][0].miner != address(0) && qubits < MAX_QUBITS) {
            if (++chemLiveRounds >= QUBIT_STEP) {
                chemLiveRounds = 0;
                ++qubits;
            }
        }
    }

    /// @notice Where the hook delivers the prize quarter of its levy.
    function prize() external payable {
        if (msg.sender != address(HOOK)) revert NotHook();
        pot += msg.value;
        emit Prize(msg.value);
    }

    function claim() external nonReentrant returns (uint256 eth) {
        eth = dueEth[msg.sender];
        if (eth == 0) revert NothingOwed();
        dueEth[msg.sender] = 0;
        _pay(msg.sender, eth);
        emit PrizeWithdrawn(msg.sender, eth);
    }

    // [03.6] BACKERS

    /// @dev Waiting stake starts taking part once the round it was placed in has settled; the running totals at that moment
    /// are written down so the newcomers earn only from there.
    function _admitWaiting(address m, Miner storage M, uint256 settling) internal {
        if (M.waiting != 0 && M.waitingRound < settling) {
            activations[m][M.waitingRound] = Activation(M.perUnitEth, M.perUnitQbt);
            M.active += M.waiting;
            M.waiting = 0;
        }
    }

    /// @dev Settles up one position: what its taking-part amount earned since the last snapshot, plus, if its queued stake has
    /// started taking part, what that earned since the moment written down for it. Each part rounds down separately, so a
    /// solver's backers together are never owed more than was set aside for them; 512-bit products keep the arithmetic in
    /// range even when a solver's only stake is one wei.
    function _refresh(address staker, address m) internal returns (Position storage P, Miner storage M) {
        M = miners[m];
        _admitWaiting(m, M, lastSettled);
        P = positions[staker][m];
        uint256 earnEth;
        uint256 earnQbt;
        if (P.amount != 0) {
            earnEth = FixedPointMathLib.fullMulDiv(P.amount, M.perUnitEth - P.snapEth, ACC);
            earnQbt = FixedPointMathLib.fullMulDiv(P.amount, M.perUnitQbt - P.snapQbt, ACC);
        }
        if (P.queued != 0 && P.waitingSince < lastSettled) {
            Activation storage act = activations[m][P.waitingSince];
            earnEth += FixedPointMathLib.fullMulDiv(P.queued, M.perUnitEth - act.perUnitEth, ACC);
            earnQbt += FixedPointMathLib.fullMulDiv(P.queued, M.perUnitQbt - act.perUnitQbt, ACC);
            P.amount += P.queued;
            P.queued = 0;
        }
        P.snapEth = M.perUnitEth;
        P.snapQbt = M.perUnitQbt;
        if (earnEth != 0) dueEth[staker] += earnEth;
        if (earnQbt != 0) dueQbt[staker] += earnQbt;
    }

    /// @notice Backs `miner` with `amount` QBT, taking part from the next round. Rounds before today must all be settled:
    /// this clears up to SELF_SETTLE_MAX of them itself and otherwise asks for `settle` first.
    function stake(address miner, uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountOutOfRange();
        _settleBehind();
        uint256 r = currentRound();
        (Position storage P, Miner storage M) = _refresh(msg.sender, miner);
        // every earlier round is settled, so any older queued stake has just started taking part
        if ((P.queued != 0 && P.waitingSince != r) || (M.waiting != 0 && M.waitingRound != r)) revert RoundsWaiting();
        QBT.transferFrom(msg.sender, address(this), amount);
        P.queued += amount;
        P.waitingSince = uint32(r);
        M.waiting += amount;
        M.waitingRound = uint32(r);
        emit Staked(msg.sender, miner, amount, r + 1);
    }

    /// @notice Withdraws stake, queued stake first. Needs nothing settled; stake withdrawn before a round settles simply
    /// takes no part in that round.
    function unstake(address miner, uint256 amount) external nonReentrant {
        (Position storage P, Miner storage M) = _refresh(msg.sender, miner);
        if (amount == 0 || amount > P.amount + P.queued) revert AmountOutOfRange();
        uint256 fromQueued = amount < P.queued ? amount : P.queued;
        if (fromQueued != 0) {
            P.queued -= fromQueued;
            M.waiting -= fromQueued;
        }
        uint256 fromLive = amount - fromQueued;
        if (fromLive != 0) {
            P.amount -= fromLive;
            M.active -= fromLive;
        }
        QBT.transfer(msg.sender, amount);
        emit Unstaked(msg.sender, miner, amount);
    }

    /// @notice Pays out what backing `miner` earned in settled rounds, together with any other ETH or QBT waiting here.
    function claimStake(address miner) external nonReentrant returns (uint256 eth, uint256 qbt) {
        _refresh(msg.sender, miner);
        eth = dueEth[msg.sender];
        qbt = dueQbt[msg.sender];
        if (eth == 0 && qbt == 0) revert NothingOwed();
        dueEth[msg.sender] = 0;
        dueQbt[msg.sender] = 0;
        if (qbt != 0) QBT.transfer(msg.sender, qbt);
        if (eth != 0) _pay(msg.sender, eth);
        emit StakeEarningsWithdrawn(msg.sender, miner, eth, qbt);
    }

    /// @notice Sets the slice of the caller's winnings that goes to its backers, 0% to 20%, from the next round. Settles the
    /// rounds before today first, so a change never reaches a round whose answers are already public.
    function setBackerShare(uint256 bps) external nonReentrant {
        if (bps > BACKER_MAX_BPS) revert BackerShareTooHigh();
        _settleBehind();
        Miner storage M = miners[msg.sender];
        uint256 r = currentRound();
        if (r >= M.backerFrom) M.backerBps = M.nextBackerBps; // the last change is in force by now
        M.nextBackerBps = uint16(bps);
        M.backerFrom = uint32(r + 1);
        emit BackerShareSet(msg.sender, bps, r + 1);
    }

    /// @dev stake and setBackerShare need every earlier round settled: then a solver never has queued stake from two rounds,
    /// and a share change never meets a round still waiting to pay. Clears up to SELF_SETTLE_MAX rounds, else reverts.
    function _settleBehind() internal {
        _settleUpTo(SELF_SETTLE_MAX);
        if (firstOpen != 0 && lastSettled < currentRound()) revert RoundsWaiting();
    }

    function _pay(address to, uint256 eth) internal {
        (bool ok,) = to.call{value: eth}("");
        if (!ok) revert EthTransferFailed();
    }
}
