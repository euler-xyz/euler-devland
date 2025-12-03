// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEVault, IERC20} from "evk/EVault/IEVault.sol";
import {RPow} from "evk/EVault/shared/lib/RPow.sol";
import {LayerCredit} from "./LayerCredit.sol";

contract LayerCreditLens {
    // word0: 20 + 1 + 1 + 5 + 5
    //   vault, state, flags(restrictedLender, restrictedBorrower), termEnd, termStart
    // word1: 1 + 2 + 2 + 2 + 2 + 2 + 2
    //   assetDecimals, cash, borrows, supplyCap, supplyAPY, borrowAPY, earlyRepayPenalty
    // word2: 1 + 20 + 8
    //   flags(col0External, col1External, col2External), col0, col1[0:8]
    // word3: 12 + 20
    //   col1[8:20], col2
    function genCompressedBond(address layerCredit, address bond) internal view returns (uint256 w0, uint256 w1, uint256 w2, uint256 w3) {
        unchecked {
            LayerCredit.BondState memory b = LayerCredit(layerCredit).getBond(bond);

            {
                uint8 bondFlags;
                if (b.restrictedLender != address(0)) bondFlags |= 2;
                if (b.restrictedBorrower != address(0)) bondFlags |= 1;

                w0 = uint160(bond);
                w0 = (w0 << 8) | b.state;
                w0 = (w0 << 8) | bondFlags;
                w0 = (w0 << 40) | b.termEnd;
                w0 = (w0 << 40) | b.termStart;
            }

            if (b.state == 0) return (w0, w1, w2, w3);

            IEVault v = IEVault(bond);

            {
                uint256 cash = v.cash();
                uint256 borrows = v.totalBorrows();

                (uint256 borrowAPY, uint256 supplyAPY) = _computeAPYs(v.interestRate(), cash, borrows, v.interestFee());
                (uint16 supplyCap,) = v.caps();

                w1 = v.decimals();
                w1 = (w1 << 16) | dfloat16(cash);
                w1 = (w1 << 16) | dfloat16(borrows);
                w1 = (w1 << 16) | supplyCap;
                w1 = (w1 << 16) | dfloat16(supplyAPY);
                w1 = (w1 << 16) | dfloat16(borrowAPY);
                w1 = (w1 << 16) | dfloat16(b.earlyRepayPenalty);
            }

            {
                address[] memory ltvs = v.LTVList();

                uint8 collateralFlags;

                if (ltvs.length >= 1) {
                    if (isEscrow(layerCredit, ltvs[0])) collateralFlags |= 4;
                    w2 |= uint160(ltvs[0]) << (8*8);
                }

                if (ltvs.length >= 2) {
                    if (isEscrow(layerCredit, ltvs[1])) collateralFlags |= 2;
                    w2 |= uint160(ltvs[1]) >> (12*8);
                    w3 |= uint160(ltvs[1]) << (20*8);
                }

                if (ltvs.length >= 2) {
                    if (isEscrow(layerCredit, ltvs[2])) collateralFlags |= 1;
                    w3 |= uint160(ltvs[2]);
                }

                w2 |= collateralFlags << (28*8);
            }
        }
    }

    function getAllActiveBonds(address layerCredit) external view returns (uint256[] memory output) {
        address[] memory bonds = LayerCredit(layerCredit).getActiveBonds(0, type(uint256).max);
        output = new uint256[](bonds.length * 4);

        uint256 offset;
        for (uint256 i; i < bonds.length; ++i) {
            (output[offset], output[offset+1], output[offset+2], output[offset+3]) = genCompressedBond(layerCredit, bonds[i]);
            offset += 4;
        }
    }



    function isEscrow(address layerCredit, address v) internal view returns (bool) {
        return LayerCredit(layerCredit).escrowVaults(IEVault(v).asset()) == v;
    }


    uint256 internal constant SECONDS_PER_YEAR = 365.2425 * 86400;

    function _computeAPYs(uint256 borrowSPY, uint256 cash, uint256 borrows, uint256 interestFee)
        internal
        pure
        returns (uint256 borrowAPY, uint256 supplyAPY)
    {
        unchecked {
            uint256 totalAssets = cash + borrows;
            bool overflow;

            (borrowAPY, overflow) = RPow.rpow(borrowSPY + 1e27, SECONDS_PER_YEAR, 1e27);

            if (overflow) return (0, 0);

            borrowAPY -= 1e27;
            supplyAPY = totalAssets == 0 ? 0 : borrowAPY * borrows * (1e4 - interestFee) / totalAssets / 1e4;

            borrowAPY /= 1e18;
            supplyAPY /= 1e18;
        }
    }


    error DFloat16Overflow();

    function dfloat16(uint256 n) internal pure returns (uint16) {
        unchecked {
            uint256 exponent = 2;

            while (n > 999) {
                exponent++;
                n /= 10;
            }

            require(exponent < 64, DFloat16Overflow());

            return uint16((n << 6) | exponent);
        }
    }
}
