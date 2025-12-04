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

    uint256 private constant MAX_COLLATERALS = 3;

    address public settingAdmin;
    uint40 public settingMaxTermDuration = 90 days; // Special value of 0 means system sunset (no new bond creation allowed)
    uint16 public settingInterestFee = 0.1e4;
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
        address oracle;
        uint256 termDuration;

        uint80 interestRate;
        address interestFeeReceiver;

        address restrictedLender;
        address restrictedBorrower;
        uint64 earlyRepayPenalty;

        DeployBondCollateral[] collaterals;
    }


    struct BondState {
        uint8 state; // 0 = none, 1 = active, 2 = soft settlement, 3 = hard settlement, 4 = inactive
        uint40 termEnd;
        uint40 termStart;
        address restrictedLender;
        address restrictedBorrower;
        uint64 earlyRepayPenalty;
        uint40 reserveMultiplier; // 1e4 scale
        uint80 settlementInterestRate;
    }

    mapping(address vault => BondState) private bondsByVault;
    EnumerableSet.AddressSet private activeBonds;
    EnumerableSet.AddressSet private settlingBonds;
    address[] private inactiveBonds;

    mapping(address vault => mapping(address who => uint256 shares)) reservedShares;


    error SystemSunset();
    error InvalidTermDuration();
    error InvalidNumberOfCollaterals();
    error InvalidAsset();
    error InvalidLTV();
    error VaultNotEVCCompatible();
    error InvalidEarlyRepayPenalty();

    function deployBond(DeployBondParams memory p) external returns (address) {
        require(settingMaxTermDuration != 0, SystemSunset());
        require(p.termDuration <= settingMaxTermDuration, InvalidTermDuration());
        require(p.collaterals.length >= 1 && p.collaterals.length <= MAX_COLLATERALS, InvalidNumberOfCollaterals());
        require(p.earlyRepayPenalty <= 1e18, InvalidEarlyRepayPenalty());

        IEulerRouter router = IEulerRouter(IEulerRouterFactory(routerFactory).deploy(address(this)));

        IEVault vault = IEVault(GenericFactory(eVaultFactory).createProxy(address(0), true, abi.encodePacked(p.asset, address(router), p.unitOfAccount)));

        vault.setInterestRateModel(address(this));
        vault.setInterestFee(settingInterestFee);
        vault.setFeeReceiver(p.interestFeeReceiver);
        vault.setHookConfig(address(this), OP_CONVERT_FEES | OP_BORROW | OP_REPAY | OP_REPAY_WITH_SHARES | OP_DEPOSIT | OP_MINT | OP_SKIM | OP_WITHDRAW | OP_REDEEM);
        vault.setMaxLiquidationDiscount(0.15e4);
        vault.setLiquidationCoolOffTime(1);

        router.govSetResolvedVault(address(vault), true);
        router.govSetConfig(p.asset, p.unitOfAccount, p.oracle);

        for (uint256 i = 0; i < p.collaterals.length; i++) {
            require(p.collaterals[i].asset != address(0), InvalidAsset());

            IEVault collateralVault;

            if (p.collaterals[i].isExternalVault) {
                collateralVault = IEVault(p.collaterals[i].asset);
                require(collateralVault.EVC() == address(evc), VaultNotEVCCompatible());
            } else {
                collateralVault = getEscrowVault(p.collaterals[i].asset);
            }

            router.govSetResolvedVault(address(collateralVault), true);

            uint16 liqLTV = p.collaterals[i].liquidationLTV;
            require(liqLTV > 0.1e4, InvalidLTV());

            router.govSetConfig(collateralVault.asset(), p.unitOfAccount, address(stubOracle));
            vault.setLTV(address(collateralVault), uint16(liqLTV * 0.98e18 / 1e18), liqLTV, 0);
            router.govSetConfig(collateralVault.asset(), p.unitOfAccount, p.collaterals[i].oracle);
        }

        router.transferGovernance(address(0));
        vault.setGovernorAdmin(address(0));

        bondsByVault[address(vault)] = BondState({
            state: 1,
            termEnd: uint40(block.timestamp + p.termDuration),
            termStart: uint40(block.timestamp),
            restrictedLender: p.restrictedLender,
            restrictedBorrower: p.restrictedBorrower,
            earlyRepayPenalty: p.earlyRepayPenalty,
            reserveMultiplier: settingReserveMultiplier,
            settlementInterestRate: settingSettlementInterestRate
        });

        activeBonds.add(address(vault));

        return address(vault);
    }

    function getEscrowVault(address asset) internal returns (IEVault) {
        if (escrowVaults[asset] != address(0)) return IEVault(escrowVaults[asset]);

        IEVault newEscrow = IEVault(GenericFactory(eVaultFactory).createProxy(address(0), true, abi.encodePacked(asset, address(0), address(0))));
        escrowVaults[asset] = address(newEscrow);

        newEscrow.setGovernorAdmin(address(0));

        return newEscrow;
    }

    function getBond(address bond) external view returns (BondState memory) {
        return bondsByVault[bond];
    }

    function getActiveBonds(uint256 start, uint256 end) external view returns (address[] memory) {
        return getSlice(activeBonds, start, end);
    }


    error SliceOutOfBounds();

    function getSlice(EnumerableSet.AddressSet storage arr, uint256 start, uint256 end) internal view returns (address[] memory) {
        uint256 length = arr.length();
        if (end == type(uint256).max) end = length;
        if (end < start || end > length) revert SliceOutOfBounds();

        address[] memory slice = new address[](end - start);
        for (uint256 i; i < end - start; ++i) {
            slice[i] = arr.at(start + i);
        }

        return slice;
    }
}
