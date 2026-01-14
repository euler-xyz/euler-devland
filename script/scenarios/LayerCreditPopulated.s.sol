// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {LayerCreditBasic} from "./LayerCreditBasic.s.sol";

import {LayerCredit} from "../../src/LayerCredit.sol";


contract LayerCreditPopulated is LayerCreditBasic {
    uint80 constant ir2p5 = 782477743732417849;
    uint80 constant ir5p0 = 1546098755264741952;
    uint80 constant ir6p25 = 1921117789660685933;
    uint80 constant ir11p2 = 3364082691096290665;

    struct NewBondParams {
        address asset;
        uint256 termDuration;
        uint80 interestRate;
        uint16 earlyRepayPenalty;
        address col0;
        uint16 ltv0;
        address col1;
        uint16 ltv1;
        address col2;
        uint16 ltv2;
    }

    function setup() internal virtual override {
        super.setup();

        vm.startBroadcast(user0PK);

        deployBond(NewBondParams({
            asset: address(assetWETH),
            termDuration: 90 days,
            interestRate: ir2p5,
            earlyRepayPenalty: 0e4,
            col0: address(assetUSDC),
            ltv0: 0.85e4,
            col1: address(0),
            ltv1: 0,
            col2: address(0),
            ltv2: 0
        }));

        vm.warp(block.timestamp + 10 days);

        deployBond(NewBondParams({
            asset: address(assetUSDC),
            termDuration: 90 days,
            interestRate: ir5p0,
            earlyRepayPenalty: 0.5e4,
            col0: address(assetWETH),
            ltv0: 0.8e4,
            col1: address(assetwstETH),
            ltv1: 0.78e4,
            col2: address(eWETH),
            ltv2: 0.6e4
        }));

        vm.stopBroadcast();
    }

    function deployBond(NewBondParams memory p) internal {
        uint256 nCol = 1;
        if (p.col1 != address(0)) nCol++;
        if (p.col2 != address(0)) nCol++;

        LayerCredit.DeployBondCollateral[] memory collaterals = new LayerCredit.DeployBondCollateral[](nCol);

        collaterals[0].asset = address(p.col0);
        collaterals[0].oracle = address(oracle);
        collaterals[0].liquidationLTV = p.ltv0;

        if (nCol >= 2) {
            collaterals[1].asset = address(p.col1);
            collaterals[1].oracle = address(oracle);
            collaterals[1].liquidationLTV = p.ltv1;
        }

        if (nCol >= 3) {
            collaterals[2].asset = address(p.col2);
            collaterals[2].oracle = address(oracle);
            collaterals[2].liquidationLTV = p.ltv2;
        }

        layerCredit.deployBond(LayerCredit.DeployBondParams({
            asset: address(p.asset),
            unitOfAccount: unitOfAccount,
            oracle: address(oracle),
            termDuration: p.termDuration,

            lender: address(0),
            borrower: address(0),
            interestRate: p.interestRate,
            earlyRepayPenalty: p.earlyRepayPenalty,
            penaltyReceiver: address(0),

            collaterals: collaterals
        }));
    }
}
