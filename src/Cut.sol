// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// QUBITENSOR · TECHNICAL DIRECTIVE TD-04 · SUBNET 0: MAX-CUT
//
// 04.1 The graph. n nodes and 2n weighted edges. Edge e is read from 64 bits of keccak(seed, e / 4), starting at bit
//      64 * (e % 4): bits 0 to 19, taken mod n, give one end; bits 20 to 39, mod n, the other (moved one node on if the two
//      coincide); bits 40 to 42 plus one give the weight, 1 to 8. Max-Cut is the benchmark QAOA, the best-known near-term
//      quantum algorithm, was designed around: divide the nodes in two so the edges running between the halves weigh as
//      much as possible.
// 04.2 The answer. One bit per node, n / 8 bytes, node x in bit x % 8 of byte x / 8. Node 0 always sits on side 0, so a
//      division and its mirror image are the same answer.
// 04.3 The reading. The weight of the edges crossing the division, and the weight of all edges.
// 04.4 The bar. 85% of the total weight. Measured on graphs drawn exactly this way (econ/par.mjs, 128 to 1,024 nodes): a
//      random division reaches 50%, one greedy pass about 81%, a single 400-sweep annealing run 86.5% at the median and
//      short of 85% on roughly one graph in ten below 512 nodes, the best of four such runs 85.5% at worst and 87.2% at the
//      median. Below the bar an answer earns nothing.
// 04.5 Cost. Measured in test/Scorers.t.sol: 172,738 gas to read 256 nodes, 2,648,404 to read 4,096, about 320 gas an
//      edge. tools/core.mjs repeats every step in JavaScript.

contract Cut {
    error BadNodes();
    error BadAnswer();
    error NotCanonical();

    /// @notice Reads the division `side` against the graph drawn from `seed` with `n` nodes. Returns the weight crossing
    /// the division and the weight of the whole graph.
    function score(bytes32 seed, uint256 n, bytes calldata side) external pure returns (uint256 cut, uint256 total) {
        if (n < 64 || n > 4096 || n % 8 != 0) revert BadNodes();
        if (side.length != n / 8) revert BadAnswer();
        if (uint8(side[0]) & 1 != 0) revert NotCanonical();
        // 2n edges at four per keccak word: n / 2 words, a whole number because n is a multiple of 8
        assembly ("memory-safe") {
            let off := side.offset
            let words := shr(1, n) // n / 2 hashes
            for { let w := 0 } lt(w, words) { w := add(w, 1) } {
                mstore(0x00, seed)
                mstore(0x20, w)
                let word := keccak256(0x00, 0x40)
                for { let j := 0 } lt(j, 4) { j := add(j, 1) } {
                    let chunk := shr(mul(64, j), word)
                    let u := mod(and(chunk, 0xfffff), n)
                    let v := mod(and(shr(20, chunk), 0xfffff), n)
                    if eq(u, v) { v := mod(add(u, 1), n) }
                    let weight := add(1, and(shr(40, chunk), 7))
                    total := add(total, weight)
                    let bu := and(shr(and(u, 7), byte(0, calldataload(add(off, shr(3, u))))), 1)
                    let bv := and(shr(and(v, 7), byte(0, calldataload(add(off, shr(3, v))))), 1)
                    if xor(bu, bv) { cut := add(cut, weight) }
                }
            }
        }
    }

    /// @notice The whole edge list (both ends and the weight of each), for solvers and for anyone checking a reading.
    function edges(bytes32 seed, uint256 n) external pure returns (uint256[] memory u, uint256[] memory v, uint256[] memory w) {
        if (n < 64 || n > 4096 || n % 8 != 0) revert BadNodes();
        uint256 m = 2 * n;
        u = new uint256[](m);
        v = new uint256[](m);
        w = new uint256[](m);
        for (uint256 e; e < m; ++e) {
            uint256 chunk = uint256(keccak256(abi.encodePacked(seed, e >> 2))) >> (64 * (e & 3));
            u[e] = (chunk & 0xfffff) % n;
            v[e] = ((chunk >> 20) & 0xfffff) % n;
            if (v[e] == u[e]) v[e] = (u[e] + 1) % n;
            w[e] = 1 + ((chunk >> 40) & 7);
        }
    }
}
