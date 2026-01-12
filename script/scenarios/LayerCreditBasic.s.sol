// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {DeployScenario} from "../DeployScenario.s.sol";

import {LayerCredit} from "../../src/LayerCredit.sol";
import {LayerCreditLens} from "../../src/LayerCreditLens.sol";

contract LayerCreditBasic is DeployScenario {
    LayerCredit layerCredit;
    LayerCreditLens layerCreditLens;

    function setup() internal virtual override {
        vm.startBroadcast(user0PK);

        deployLayerCredit();

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

        string memory result = vm.serializeAddress("layerCreditAddresses", "layerCredit", address(layerCredit));
        result = vm.serializeAddress("layerCreditAddresses", "layerCreditLens", address(layerCreditLens));
        vm.writeJson(result, "./dev-ctx/addresses/31337/LayerCreditAddresses.json");
    }

    function deployLayerCredit() internal {
        layerCredit = new LayerCredit(address(evc), address(factory), address(routerFactory));
        layerCreditLens = new LayerCreditLens();

        string memory result = vm.serializeAddress("layerCredit", "layerCredit", address(layerCredit));
        result = vm.serializeAddress("layerCredit", "layerCreditLens", address(layerCreditLens));
        vm.writeJson(result, "./dev-ctx/addresses/31337/LayerCredit.json");
    }
}
