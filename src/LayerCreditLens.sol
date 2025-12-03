// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEVault, IERC20} from "evk/EVault/IEVault.sol";
import {RPow} from "evk/EVault/shared/lib/RPow.sol";
import {LayerCredit} from "./LayerCredit.sol";

contract LayerCreditLens {
    // vault, bondId, state, termEnd, termStart, flags(restrictedLender, restrictedBorrower), supplyAPY, borrowAPY, supplyCap, collaterals
    // 20 + 5 + 1 + 5 + 5 + 1 + 6 + 6 + 2 + N
    function activeBonds(address layerCreditAddr) external view returns (bytes[] memory output) {
    /*
        unchecked {
            output = new bytes[](vaults.length);
            for (uint256 i; i < vaults.length; ++i) {
                IEVault v = IEVault(vaults[i]);
                output[i] = abi.encodePacked(v.asset(), v.decimals(), v.symbol());
            }
        }
        */
    }
}
