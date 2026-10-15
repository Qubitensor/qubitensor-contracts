// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// site: https://qubitensor.xyz   x: https://x.com/Qubitensor
//
// QUBITENSOR · TECHNICAL DIRECTIVE TD-05 · SUBNET 1: THE GROUND STATE
//
// 05.1 The magnet. q qubits, 6 to 8: H = sum over pairs J_ij Z_i Z_j + sum h_i X_i, every J_ij between -1 and 1 and
//      every h_i between 0 and 1, drawn from the round's seed. It stands in for a molecule in variational quantum
//      algorithms: short to state, hard to settle into its lowest-energy state.
// 05.2 The circuit. Four layers, each an RY turn on every qubit followed by CZ between neighbours (q - 1 of them), then one
//      more RY layer. An angle is a 16-bit k, a turn of RY(2 pi k / 65,536). RY and CZ keep every amplitude real.
// 05.3 The reading. The circuit runs from |0...0> in fixed point (amplitudes in units of 2^-62, rounded down), and the
//      energy is the Rayleigh quotient <a|H|a> / <a|a>, computed exactly in integers from the amplitudes as they stand.
//      That quotient can never fall below the true ground energy, whatever the vector, so rounding cannot carry an
//      answer under the ground state; the final division rounds up. Units of 2^-60.
// 05.4 The bar. The lowest energy of any single bit-string, the classical floor with no superposition. An answer counts
//      only below it. Measured in econ/lab.js: even one layer of unentangled turns clears it by 0.7 to 1.7.
// 05.5 Same everywhere. Integer arithmetic only, with floor shifts and truncating division of non-negative numbers;
//      tools/core.mjs repeats it step for step, so a solver knows the exact score before sealing.
// 05.6 Cost. Measured in test/Scorers.t.sol: 467,130 gas to read 6 qubits, 1,722,644 to read 8.

contract Chem {
    uint256 public constant LAYERS = 4;
    uint256 public constant MIN_QUBITS = 6;
    uint256 public constant MAX_QUBITS = 8;
    int256 internal constant UNIT = 1 << 62; // an amplitude of exactly 1
    uint256 internal constant PI_Q62 = 14488038916154245685; // pi in units of 2^-62, rounded to nearest
    uint256 internal constant J_SPAN = (1 << 21) + 1; // couplings run from -2^20 to 2^20 inclusive
    uint256 internal constant H_SPAN = (1 << 20) + 1; // fields run from 0 to 2^20 inclusive

    error BadQubits();
    error BadAngles();

    /// @notice How many 16-bit angles an answer for `q` qubits must hold: five layers of q.
    function angleCount(uint256 q) public pure returns (uint256) {
        return q * (LAYERS + 1);
    }

    /// @notice Runs the circuit `angles` describes and reads its energy on the magnet drawn from `seed`, alongside the bar
    /// (the best bit-string). Both in units of 2^-60; lower is better, and only an energy under the bar counts.
    function score(bytes32 seed, uint256 q, bytes calldata angles) external pure returns (int256 energy, int256 par) {
        if (q < MIN_QUBITS || q > MAX_QUBITS) revert BadQubits();
        if (angles.length != 2 * angleCount(q)) revert BadAngles();
        uint256 dim = 1 << q;
        (int256[] memory diag, int256[] memory h, int256 minDiag) = _magnet(seed, q);
        int256[] memory a = new int256[](dim);
        a[0] = UNIT;
        uint256 p;
        for (uint256 l; l < LAYERS; ++l) {
            for (uint256 k; k < q; ++k) _rotate(a, k, _angle(angles, p++));
            for (uint256 k; k + 1 < q; ++k) _entangle(a, k);
        }
        for (uint256 k; k < q; ++k) _rotate(a, k, _angle(angles, p++));
        energy = _quotient(a, diag, h, q);
        par = minDiag * int256(1 << 40);
    }

    /// @notice The magnet in full, in units of 2^-20: a coupling for each pair i < j in order, then a field per qubit.
    function magnet(bytes32 seed, uint256 q) external pure returns (int256[] memory j, int256[] memory h) {
        if (q < MIN_QUBITS || q > MAX_QUBITS) revert BadQubits();
        uint256 pairs = (q * (q - 1)) / 2;
        j = new int256[](pairs);
        h = new int256[](q);
        for (uint256 k; k < pairs; ++k) j[k] = int256(_bits32(seed, k) % J_SPAN) - int256(1 << 20);
        for (uint256 k; k < q; ++k) h[k] = int256(_bits32(seed, pairs + k) % H_SPAN);
    }

    // [05.1] THE MAGNET

    /// @dev Draw number k: 32 bits of keccak(seed, k / 8), starting at bit 32 * (k % 8).
    function _bits32(bytes32 seed, uint256 k) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            mstore(0x00, seed)
            mstore(0x20, shr(3, k))
            r := and(shr(mul(32, and(k, 7)), keccak256(0x00, 0x40)), 0xffffffff)
        }
    }

    /// @dev The Z-part energy of all 2^q bit-strings, built up a bit at a time. With b < 2^t (bit t and all higher bits 0)
    /// and s = +1 for a 0 bit, -1 for a 1 bit: D[b + 2^t] = D[b] - 2 (sum over j < t of J_tj s_j(b) + sum over j > t of J_tj).
    function _magnet(bytes32 seed, uint256 q) internal pure returns (int256[] memory diag, int256[] memory h, int256 minDiag) {
        uint256 pairs = (q * (q - 1)) / 2;
        int256[] memory m = new int256[](q * q); // couplings laid out as a full q by q table, zero down the middle
        h = new int256[](q);
        int256 d0; // the all-zero string: every pair aligned, so every coupling counts once
        uint256 k;
        for (uint256 x; x < q; ++x) {
            for (uint256 y = x + 1; y < q; ++y) {
                int256 jv = int256(_bits32(seed, k) % J_SPAN) - int256(1 << 20);
                m[x * q + y] = jv;
                m[y * q + x] = jv;
                d0 += jv;
                ++k;
            }
        }
        for (uint256 x; x < q; ++x) h[x] = int256(_bits32(seed, pairs + x) % H_SPAN);
        diag = new int256[](1 << q);
        assembly ("memory-safe") {
            let dp := add(diag, 0x20)
            let mp := add(m, 0x20)
            mstore(dp, d0)
            let mn := d0
            for { let t := 0 } lt(t, q) { t := add(t, 1) } {
                let row := add(mp, shl(5, mul(t, q)))
                let upper := 0
                for { let j := add(t, 1) } lt(j, q) { j := add(j, 1) } { upper := add(upper, mload(add(row, shl(5, j)))) }
                let half := shl(t, 1)
                for { let b := 0 } lt(b, half) { b := add(b, 1) } {
                    let f := upper
                    for { let j := 0 } lt(j, t) { j := add(j, 1) } {
                        let mj := mload(add(row, shl(5, j)))
                        switch and(shr(j, b), 1)
                        case 0 { f := add(f, mj) }
                        default { f := sub(f, mj) }
                    }
                    let v := sub(mload(add(dp, shl(5, b))), mul(2, f))
                    mstore(add(dp, shl(5, add(b, half))), v)
                    if slt(v, mn) { mn := v }
                }
            }
            minDiag := mn
        }
    }

    // [05.2] THE CIRCUIT

    function _angle(bytes calldata angles, uint256 i) internal pure returns (uint256) {
        return (uint256(uint8(angles[2 * i])) << 8) | uint256(uint8(angles[2 * i + 1]));
    }

    /// @dev RY(2 pi k / 65,536) on qubit `q`. For each index pair differing only in bit q, amplitudes (x, y) turn into
    /// (c x - s y, s x + c y) >> 62, where c and s are the cosine and sine of pi k / 65,536. Every pair is visited once.
    function _rotate(int256[] memory a, uint256 q, uint256 k) internal pure {
        (int256 c, int256 s) = _cosSin(k);
        assembly ("memory-safe") {
            let ap := add(a, 0x20)
            let dim := mload(a)
            let bit := shl(q, 1)
            let stride := shl(5, bit)
            let blk := shl(1, bit)
            for { let base := 0 } lt(base, dim) { base := add(base, blk) } {
                let px := add(ap, shl(5, base))
                let last := add(px, stride)
                for { } lt(px, last) { px := add(px, 0x20) } {
                    let py := add(px, stride)
                    let x := mload(px)
                    let y := mload(py)
                    mstore(px, sar(62, sub(mul(c, x), mul(s, y))))
                    mstore(py, sar(62, add(mul(s, x), mul(c, y))))
                }
            }
        }
    }

    /// @dev CZ across qubits `q` and `q + 1`: flips the sign of each amplitude whose index has both bits set.
    function _entangle(int256[] memory a, uint256 q) internal pure {
        assembly ("memory-safe") {
            let ap := add(a, 0x20)
            let dim := mload(a)
            let low := shl(q, 1)
            let both := mul(3, low)
            let blk := shl(add(q, 2), 1)
            for { let hi := 0 } lt(hi, dim) { hi := add(hi, blk) } {
                let p := add(ap, shl(5, add(hi, both)))
                let last := add(p, shl(5, low))
                for { } lt(p, last) { p := add(p, 0x20) } { mstore(p, sub(0, mload(p))) }
            }
        }
    }

    /// @dev Cosine and sine of pi k / 65,536 for k below 65,536, in units of 2^-62: fold the angle into [0, pi / 4], then
    /// sum Taylor terms up to x^20, where what is left over is under 2^-70.
    function _cosSin(uint256 k) internal pure returns (int256 c, int256 s) {
        bool negCos;
        if (k > 32768) {
            k = 65536 - k; // reflect about pi / 2: same sine, cosine negated
            negCos = true;
        }
        bool swap;
        if (k > 16384) {
            k = 32768 - k; // reflect about pi / 4: sine and cosine swap
            swap = true;
        }
        uint256 x = (k * PI_Q62) >> 16;
        (uint256 cu, uint256 su) = _series(x);
        if (swap) (cu, su) = (su, cu);
        c = negCos ? -int256(cu) : int256(cu);
        s = int256(su);
    }

    function _series(uint256 x) internal pure returns (uint256 cosX, uint256 sinX) {
        unchecked {
            uint256 x2 = (x * x) >> 62;
            // sine: alternating odd powers over their factorials, up to x^19
            uint256 t = x;
            uint256 sum = x;
            for (uint256 i = 1; i <= 9; ++i) {
                t = ((t * x2) >> 62) / ((2 * i) * (2 * i + 1));
                sum = i & 1 == 1 ? sum - t : sum + t;
            }
            sinX = sum;
            // cosine: alternating even powers over their factorials, up to x^20
            t = uint256(UNIT);
            sum = uint256(UNIT);
            for (uint256 i = 1; i <= 10; ++i) {
                t = ((t * x2) >> 62) / ((2 * i - 1) * (2 * i));
                sum = i & 1 == 1 ? sum - t : sum + t;
            }
            cosX = sum;
        }
    }

    // [05.3] THE READING

    /// @dev <a|H|a> / <a|a> in units of 2^-60, rounded up: every sum exact, one division at the end. An X term counts each
    /// pair of amplitudes once and doubles it, which equals going over every index.
    function _quotient(int256[] memory a, int256[] memory diag, int256[] memory h, uint256 q) internal pure returns (int256) {
        int256 num;
        int256 norm;
        assembly ("memory-safe") {
            let ap := add(a, 0x20)
            let dp := add(diag, 0x20)
            let dim := mload(a)
            for { let b := 0 } lt(b, dim) { b := add(b, 1) } {
                let x := mload(add(ap, shl(5, b)))
                let sq := mul(x, x)
                norm := add(norm, sq)
                num := add(num, mul(mload(add(dp, shl(5, b))), sq))
            }
            let hp := add(h, 0x20)
            for { let t := 0 } lt(t, q) { t := add(t, 1) } {
                let bit := shl(t, 1)
                let stride := shl(5, bit)
                let blk := shl(1, bit)
                let off := 0
                for { let base := 0 } lt(base, dim) { base := add(base, blk) } {
                    let px := add(ap, shl(5, base))
                    let last := add(px, stride)
                    for { } lt(px, last) { px := add(px, 0x20) } { off := add(off, mul(mload(px), mload(add(px, stride)))) }
                }
                num := add(num, mul(mload(add(hp, shl(5, t))), mul(2, off)))
            }
        }
        // num carries units of 2^-20 times amplitude squared, norm units of amplitude squared; round toward plus infinity
        if (num >= 0) return int256((uint256(num) * (1 << 40) + uint256(norm) - 1) / uint256(norm));
        return -int256((uint256(-num) * (1 << 40)) / uint256(norm));
    }
}
