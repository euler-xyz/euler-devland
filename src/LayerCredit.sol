// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEVault, IERC20} from "evk/EVault/IEVault.sol";
import {IEulerRouterFactory, IEulerRouter} from "./interfaces/Misc.sol";
import "evk/EVault/shared/Constants.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {StubOracle} from "./StubOracle.sol";

contract LayerCredit {
    GenericFactory immutable private eVaultFactory;
    IEulerRouterFactory immutable private routerFactory;
    StubOracle immutable private stubOracle;

    address public settingAdmin;
    uint16 public settingNumVaultLimit; // Special value of 0 means system sunset (no new bond creation allowed)
    uint40 public settingMaxTermDuration;
    uint40 public settingReserveMultiplier; // 1e4 scale
    uint256 public settlementInterestRate;

    constructor(address eVaultFactory_, address routerFactory_, address settingAdmin_) {
        eVaultFactory = GenericFactory(eVaultFactory_);
        routerFactory = IEulerRouterFactory(routerFactory_);
        stubOracle = new StubOracle();

        settingAdmin = settingAdmin_;
        settingNumVaultLimit = 4;
        settingMaxTermDuration = 90 days;
        settingReserveMultiplier = 20e4;
        settlementInterestRate = 21964959992727444861; // 100% APY
    }

    struct DeployBondVault {
        address asset;
        address oracle;
        uint256 interestRate;
        address restrictedLender;
        address restrictedBorrower;
        bool noEarlyRepay;
    }

    struct DeployBondLTV {
        uint256 collateralIndex;
        uint256 liabilityIndex;
        uint16 liquidationLTV;
    }

    struct DeployBondParams {
        address unitOfAccount;
        uint256 termDuration;
        uint256 interestFee;
        address interestFeeRecipient;
        DeployBondVault[] vaults;
        DeployBondLTV[] ltvs;
    }

    error SystemSunset();
    error InvalidTermDuration();
    error InvalidNumberOfVaults();
    error InvalidLTVIndex();

    function deployBond(DeployBondParams memory p) external {
        require(settingNumVaultLimit != 0, SystemSunset());
        require(p.termDuration <= settingMaxTermDuration, InvalidTermDuration());

        require(p.vaults.length >= 2 && p.vaults.length <= settingNumVaultLimit, InvalidNumberOfVaults());

        IEulerRouter router = IEulerRouter(IEulerRouterFactory(routerFactory).deploy(address(this)));

        IEVault[] memory vaults = new IEVault[](p.vaults.length);

        for (uint256 i = 0; i < p.vaults.length; i++) {
            IEVault vault = vaults[i] = IEVault(GenericFactory(eVaultFactory).createProxy(address(0), true, abi.encodePacked(p.vaults[i].asset, address(router), p.unitOfAccount)));

            vault.setInterestRateModel(address(this));
            vault.setHookConfig(address(this), OP_CONVERT_FEES | OP_BORROW | OP_REPAY | OP_REPAY_WITH_SHARES | OP_DEPOSIT | OP_MINT | OP_SKIM | OP_VAULT_STATUS_CHECK);
            vault.setMaxLiquidationDiscount(0.15e4);
            vault.setLiquidationCoolOffTime(1);

            router.govSetResolvedVault(address(vault), true);
            router.govSetConfig(p.vaults[i].asset, p.unitOfAccount, address(stubOracle));
        }

        for (uint256 i = 0; i < p.ltvs.length; i++) {
            require(p.ltvs[i].collateralIndex < p.vaults.length, InvalidLTVIndex());
            require(p.ltvs[i].liabilityIndex < p.vaults.length, InvalidLTVIndex());

            vaults[p.ltvs[i].liabilityIndex].setLTV(address(vaults[p.ltvs[i].collateralIndex]), uint16(p.ltvs[i].liquidationLTV * 0.98e18 / 1e18), p.ltvs[i].liquidationLTV, 0);
        }

        // Install final oracles

        for (uint256 i = 0; i < p.vaults.length; i++) {
            router.govSetConfig(p.vaults[i].asset, p.unitOfAccount, p.vaults[i].oracle);
        }

        router.transferGovernance(address(0));
    }
}
