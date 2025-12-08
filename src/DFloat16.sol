// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

library DFloat16 {
    error DFloat16Overflow();

    function to_dfloat16(uint256 n) internal pure returns (uint16) {
        if (n == type(uint256).max) return 0;

        unchecked {
            uint256 exponent = 2;

            while (n >= 1000) {
                exponent++;
                n /= 10;
            }

            require(exponent < 64, DFloat16Overflow());

            return uint16((n << 6) | exponent);
        }
    }

    function from_dfloat16(uint16 f) internal pure returns (uint256) {
        if (f == 0) return type(uint256).max;

        unchecked {
            // Cannot overflow because this is less than 2**256:
            //   10**(2**6 - 1) * (2**10 - 1) = 1.023e+66
            return 10 ** (f & 63) * (f >> 6) / 100;
        }
    }
}
