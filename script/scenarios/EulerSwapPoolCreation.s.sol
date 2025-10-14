// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {DeployScenario} from "../DeployScenario.s.sol";
import {IEulerSwap} from "euler-swap/interfaces/IEulerSwap.sol";
import {IEulerSwapFactory} from "euler-swap/interfaces/IEulerSwapFactory.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "../../libflat/euler-swap/test/utils/HookMiner.sol";
import {MetaProxyDeployer} from "euler-swap/utils/MetaProxyDeployer.sol";

import {Test} from "forge-std/Test.sol";

contract EulerSwapPoolCreation is DeployScenario, Test {
    function setup() internal virtual override {
        vm.startBroadcast(user3PK);
        giveLotsOfCash(user0);
        vm.stopBroadcast();

        vm.startBroadcast(user0PK);

        // Deposit liquidity into vaults
        assetUSDC.approve(address(eUSDC), type(uint256).max);
        eUSDC.deposit(100000e6, user0);

        assetUSDT.approve(address(eUSDT), type(uint256).max);
        eUSDT.deposit(100000e6, user0);

        // Create USDC/USDT pool with 1:1 price
        // Note: assets must be ordered (asset0 < asset1)
        address vault0 = address(eUSDC);
        address vault1 = address(eUSDT);

        // Swap if needed to ensure proper ordering
        if (IEVault(vault0).asset() > IEVault(vault1).asset()) {
            (vault0, vault1) = (vault1, vault0);
        }

        // Prepare pool parameters
        IEulerSwap.StaticParams memory sParams = IEulerSwap.StaticParams({
            supplyVault0: vault0,
            supplyVault1: vault1,
            borrowVault0: vault0,
            borrowVault1: vault1,
            eulerAccount: user0,
            feeRecipient: user0,
            protocolFee: 0,
            protocolFeeRecipient: address(0)
        });

        IEulerSwap.DynamicParams memory dParams = IEulerSwap.DynamicParams({
            equilibriumReserve0: 10000e18, // 10k virtual reserves
            equilibriumReserve1: 10000e18, // 10k virtual reserves
            minReserve0: 0,
            minReserve1: 0,
            priceX: 1e18, // 1:1 price
            priceY: 1e18,
            concentrationX: 0.5e18, // 50% concentration
            concentrationY: 0.5e18, // 50% concentration
            fee0: 0.003e18, // 0.3% fee
            fee1: 0.003e18, // 0.3% fee
            expiration: 0,
            swapHookedOperations: 0,
            swapHook: address(0)
        });

        // Prepare initial state
        IEulerSwap.InitialState memory initialState = IEulerSwap.InitialState({reserve0: 10000e18, reserve1: 10000e18});

        // Mine salt using HookMiner to find a valid hook address
        console.log("\nMining salt for valid hook address...");
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        // Prepare creation code
        bytes memory creationCode = MetaProxyDeployer.creationCodeMetaProxy(eulerSwapImpl, abi.encode(sParams));
        (address hookAddress, bytes32 salt) = HookMiner.find(address(eulerSwapFactory), flags, creationCode);

        console.log("Found salt:", uint256(salt));
        console.log("Hook address:", hookAddress);
        console.log("Hook address flags:", uint160(hookAddress) & Hooks.ALL_HOOK_MASK);
        console.log("Expected flags:", flags);

        // Deploy pool via EVC batch
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            onBehalfOfAccount: address(0),
            targetContract: address(evc),
            value: 0,
            data: abi.encodeCall(evc.setAccountOperator, (user0, hookAddress, true))
        });
        items[1] = IEVC.BatchItem({
            onBehalfOfAccount: user0,
            targetContract: address(eulerSwapFactory),
            value: 0,
            data: abi.encodeCall(IEulerSwapFactory.deployPool, (sParams, dParams, initialState, salt))
        });
        console.log("\nDeploying EulerSwap pool...");
        console.log("Pool manager address:", address(poolManager));
        console.log("EulerSwap implementation:", address(eulerSwapImpl));
        evc.batch(items);
        console.log("SUCCESS! Pool deployed at:", hookAddress);

        // Enable vaults as collateral
        evc.enableCollateral(user0, vault0);
        evc.enableCollateral(user0, vault1);
        vm.stopBroadcast();

        // Print results
        console.log("");
        console.log("===== EulerSwap Pool Creation Scenario =====");
        console.log("");
        console.log("Setup complete:");
        console.log("- User0 deposited 100k USDC and 100k USDT");
        console.log("- Both vaults enabled as collateral");
        console.log("- USDC Vault:", vault0);
        console.log("- USDT Vault:", vault1);

        // Check if pool exists
        address deployedPool = eulerSwapRegistry.poolByEulerAccount(user0);
        if (deployedPool != address(0)) {
            console.log("- Pool deployed at:", deployedPool);
            console.log("");
            console.log("Pool is ready for swaps and liquidity provision!");
        } else {
            console.log("");
            console.log("Error: Pool deployment may have failed!");
        }
    }
}
