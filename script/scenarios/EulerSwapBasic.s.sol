// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// Euler swap

import {IEVault} from "evk/EVault/IEVault.sol";
import {IEulerSwap, IEVC, EulerSwap} from "euler-swap/EulerSwap.sol";
import {EulerSwapFactory} from "euler-swap/EulerSwapFactory.sol";
import {EulerSwapPeriphery} from "euler-swap/EulerSwapPeriphery.sol";
import {PoolManagerDeployer} from "euler-swap/../test/utils/PoolManagerDeployer.sol";

// Maglev stuff

import {MaglevLens} from "src/MaglevLens.sol";


import {DeployScenario} from "../DeployScenario.s.sol";

contract EulerSwapBasic is DeployScenario {
    //////// EulerSwap

    address poolManager;
    address eulerSwapImpl;
    EulerSwapFactory eulerSwapFactory;
    EulerSwapPeriphery eulerSwapPeriphery;

    //////// Maglev

    MaglevLens maglevLens;

    function setup() internal virtual override {
        vm.startBroadcast(user0PK);

        deployEulerSwap();
        deployMaglevLens();

        giveLotsOfCash(user0);

        // Deposit some assets

        assetUSDC.approve(address(eUSDC), type(uint256).max);
        eUSDC.deposit(20000e6, user0);

        assetUSDT.approve(address(eUSDT), type(uint256).max);
        eUSDT.deposit(10000e6, user0);

        assetWETH.approve(address(eWETH), type(uint256).max);
        eWETH.deposit(10e18, user0);

        assetUSDZ.approve(address(eUSDZ), type(uint256).max);
        eUSDZ.deposit(10000e6, user0);

        // Some extra USDT to subaccount 1
        assetUSDT.approve(address(eUSDT), type(uint256).max);
        eUSDT.deposit(5000e6, getSubaccount(user0, 1));

        vm.stopBroadcast();
    }

    function deployEulerSwap() internal {
        poolManager = address(PoolManagerDeployer.deploy(address(0)));
        eulerSwapImpl = address(new EulerSwap(address(evc), poolManager));
        eulerSwapFactory = new EulerSwapFactory(address(evc), address(factory), eulerSwapImpl, address(0), address(0));
        eulerSwapPeriphery = new EulerSwapPeriphery();

        string memory result = vm.serializeAddress("eulerSwap", "eulerSwapFactory", address(eulerSwapFactory));
        result = vm.serializeAddress("eulerSwap", "eulerSwapPeriphery", address(eulerSwapPeriphery));
        vm.writeJson(result, "./dev-ctx/addresses/31337/EulerSwapAddresses.json");
    }

    function deployMaglevLens() internal {
        maglevLens = new MaglevLens();

        string memory result = vm.serializeAddress("maglev", "maglevLens", address(maglevLens));
        vm.writeJson(result, "./dev-ctx/addresses/31337/MaglevAddresses.json");
    }
}
