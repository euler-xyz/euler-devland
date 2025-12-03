// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {EnumerableSet} from "openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {EVCUtil} from "evc/utils/EVCUtil.sol";
import {IEVault, IERC20} from "evk/EVault/IEVault.sol";
import "evk/EVault/shared/Constants.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEulerRouterFactory, IEulerRouter} from "./interfaces/Misc.sol";
import {StubOracle} from "./StubOracle.sol";

contract LayerCredit is EVCUtil {
    using EnumerableSet for EnumerableSet.AddressSet;

    GenericFactory immutable private eVaultFactory;
    IEulerRouterFactory immutable private routerFactory;
    StubOracle immutable private stubOracle;

    address public settingAdmin;
    uint16 public settingMaxCollaterals = 3; // Special value of 0 means system sunset (no new bond creation allowed)
    uint40 public settingMaxTermDuration = 90 days;
    uint40 public settingReserveMultiplier = 20e4; // 1e4 scale
    uint80 public settingSettlementInterestRate = 21964959992727444861; // 100% APY

    mapping(address asset => address escrowVault) public escrowVaults;

    constructor(address evc, address eVaultFactory_, address routerFactory_, address settingAdmin_) EVCUtil(evc) {
        eVaultFactory = GenericFactory(eVaultFactory_);
        routerFactory = IEulerRouterFactory(routerFactory_);
        stubOracle = new StubOracle();

        settingAdmin = settingAdmin_;
    }

    struct DeployBondCollateral {
        address asset;
        bool isExternalVault;
        uint16 liquidationLTV;
        address oracle;
    }

    struct DeployBondParams {
        address asset;
        address unitOfAccount;
        uint256 termDuration;

        uint80 interestRate;
        uint16 interestFee;
        address interestFeeReceiver;

        address restrictedLender;
        address restrictedBorrower;
        uint64 earlyRepayPenalty;

        DeployBondCollateral[] collaterals;
    }


    struct BondStorage {
        address vault;
        uint40 bondId;
        uint16 state; // 0 = active, 1 = soft settlement, 2 = hard settlement, 3 = dead
        uint40 termEnd;
        uint40 termStart;
        address restrictedLender;
        address restrictedBorrower;
        uint40 reserveMultiplier; // 1e4 scale
        uint80 settlementInterestRate;
    }

    mapping(address vault => BondStorage) private bondsByVault;
    mapping(uint256 bondId => address vault) private bondsById;
    uint256 private nextBondId = 1;
    EnumerableSet.AddressSet private activeBonds;

    mapping(address vault => mapping(address who => uint256 shares)) reservedShares;


    error SystemSunset();
    error InvalidTermDuration();
    error InvalidNumberOfCollaterals();
    error InvalidLTVIndex();
    error VaultNotEVCCompatible();

    function deployBond(DeployBondParams memory p) external returns (address) {
        require(settingMaxCollaterals != 0, SystemSunset());
        require(p.termDuration <= settingMaxTermDuration, InvalidTermDuration());

        require(p.collaterals.length >= 1 && p.collaterals.length <= settingMaxCollaterals, InvalidNumberOfCollaterals());

        IEulerRouter router = IEulerRouter(IEulerRouterFactory(routerFactory).deploy(address(this)));

        IEVault vault = IEVault(GenericFactory(eVaultFactory).createProxy(address(0), true, abi.encodePacked(p.asset, address(router), p.unitOfAccount)));

        vault.setInterestRateModel(address(this));
        vault.setInterestFee(p.interestFee);
        vault.setFeeReceiver(p.interestFeeReceiver);
        vault.setHookConfig(address(this), OP_CONVERT_FEES | OP_BORROW | OP_REPAY | OP_REPAY_WITH_SHARES | OP_DEPOSIT | OP_MINT | OP_SKIM | OP_WITHDRAW | OP_REDEEM);
        vault.setMaxLiquidationDiscount(0.15e4);
        vault.setLiquidationCoolOffTime(1);

        for (uint256 i = 0; i < p.collaterals.length; i++) {
            IEVault collateralVault;

            if (p.collaterals[i].isExternalVault) {
                collateralVault = IEVault(p.collaterals[i].asset);
                require(collateralVault.EVC() == address(evc), VaultNotEVCCompatible());
            } else {
                collateralVault = getEscrowVault(p.collaterals[i].asset);
            }

            router.govSetResolvedVault(address(vault), true);

            router.govSetConfig(collateralVault.asset(), p.unitOfAccount, address(stubOracle));
            vault.setLTV(address(collateralVault), uint16(p.collaterals[i].liquidationLTV * 0.98e18 / 1e18), p.collaterals[i].liquidationLTV, 0);
            router.govSetConfig(collateralVault.asset(), p.unitOfAccount, p.collaterals[i].oracle);
        }

        router.transferGovernance(address(0));
        vault.setGovernorAdmin(address(0));

        bondsByVault[address(vault)] = BondStorage({
            vault: address(vault),
            bondId: uint40(nextBondId),
            termEnd: uint40(block.timestamp + p.termDuration),
            termStart: uint40(block.timestamp),
            restrictedLender: p.restrictedLender,
            restrictedBorrower: p.restrictedBorrower,
            reserveMultiplier: settingReserveMultiplier,
            settlementInterestRate: settingSettlementInterestRate
        });

        bondsById[nextBondId] = address(vault);

        activeBonds.add(address(vault));

        nextBondId++;

        return address(vault);
    }

    function getEscrowVault(address asset) internal returns (IEVault) {
        if (escrowVaults[asset] != address(0)) return IEVault(escrowVaults[asset]);

        IEVault newEscrow = IEVault(GenericFactory(eVaultFactory).createProxy(address(0), true, abi.encodePacked(asset, address(0), address(0))));
        escrowVaults[asset] = address(newEscrow);

        newEscrow.setGovernorAdmin(address(0));

        return newEscrow;
    }
}
