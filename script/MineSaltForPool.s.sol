// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IEulerSwap} from "euler-swap/interfaces/IEulerSwap.sol";
import {IEulerSwapFactory} from "euler-swap/interfaces/IEulerSwapFactory.sol";
import {HookMiner} from "../libflat/euler-swap/test/utils/HookMiner.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {MetaProxyDeployer} from "euler-swap/utils/MetaProxyDeployer.sol";

contract MineSaltForPool is Script {
    function run() public view {
        // Read configuration from environment or use defaults
        address vault0 = vm.envOr("VAULT0", address(0x864516a3e56ab9b821B19F6bfB898FA28f21E0cB));
        address vault1 = vm.envOr("VAULT1", address(0xB9D512FAF432Ce6A0e09b1f2B195856F9E5EE822));
        address eulerAccount = vm.envOr("EULER_ACCOUNT", address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266));
        address eulerSwapFactory = vm.envOr("FACTORY", address(0x55D09F01fBF9D8D891c6608c5a54eA7aD6d528FB));
        address eulerSwapImpl = vm.envOr("IMPL", address(0x48d617CA203f53C9909758799af38D1780b157F7));
        
        console.log("Mining salt for EulerSwap pool deployment");
        console.log("Vault0:", vault0);
        console.log("Vault1:", vault1);
        console.log("Euler Account:", eulerAccount);
        console.log("Factory:", eulerSwapFactory);
        console.log("Implementation:", eulerSwapImpl);
        console.log("");
        
        // Create pool parameters
        IEulerSwap.Params memory poolParams = IEulerSwap.Params({
            vault0: vault0,
            vault1: vault1,
            eulerAccount: eulerAccount,
            equilibriumReserve0: 10000e18,
            equilibriumReserve1: 10000e18,
            priceX: 1e18,
            priceY: 1e18,
            concentrationX: 0.5e18,
            concentrationY: 0.5e18,
            fee: 0.003e18,
            protocolFee: 0,
            protocolFeeRecipient: address(0)
        });
        
        // Define required hook flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | 
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.BEFORE_DONATE_FLAG | 
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        
        console.log("Required flags:", flags);
        console.log("Mining salt...");
        
        // Mine salt
        bytes memory creationCode = MetaProxyDeployer.creationCodeMetaProxy(eulerSwapImpl, abi.encode(poolParams));
        (address hookAddress, bytes32 salt) = HookMiner.find(eulerSwapFactory, flags, creationCode);
        
        console.log("");
        console.log("SUCCESS! Found valid salt:");
        console.log("Salt (hex):", vm.toString(salt));
        console.log("Salt (decimal):", uint256(salt));
        console.log("Hook address:", hookAddress);
        console.log("Hook flags:", uint160(hookAddress) & Hooks.ALL_HOOK_MASK);
        
        // Verify the address
        address computedAddress = IEulerSwapFactory(eulerSwapFactory).computePoolAddress(poolParams, salt);
        console.log("");
        console.log("Verification:");
        console.log("Computed address:", computedAddress);
        console.log("Matches hook address:", computedAddress == hookAddress);
    }
}