// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {EnumerableSet} from "openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {EVCUtil} from "evc/utils/EVCUtil.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import "evk/EVault/shared/Constants.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEulerRouterFactory, IEulerRouter} from "./interfaces/Misc.sol";
import {StubOracle} from "./StubOracle.sol";
import "./DFloat16.sol";

contract LayerCredit is EVCUtil {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;
    using DFloat16 for uint256;

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
        address oracle;
        uint16 liquidationLTV;
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


    uint8 internal constant BOND_STATE_ACTIVE = 1;
    uint8 internal constant BOND_STATE_SOFT_SETTLEMENT = 2;
    uint8 internal constant BOND_STATE_HARD_SETTLEMENT = 3;
    uint8 internal constant BOND_STATE_FINAL = 4;

    // FIXME: pack this
    struct BondState {
        uint8 state;
        uint40 termEnd;
        uint40 termStart;
        address restrictedLender;
        address restrictedBorrower;
        uint64 earlyRepayPenalty;
        uint80 interestRate;
        uint40 reserveMultiplier; // 1e4 scale
        uint80 settlementInterestRate;
        uint40 nextTransitionTime;
    }

    mapping(address vault => BondState) private bondsByVault;
    EnumerableSet.AddressSet private activeBonds;
    EnumerableSet.AddressSet private settlingBonds;
    address[] private inactiveBonds;

    mapping(address vault => mapping(address who => uint256 shares)) public reservedShares;
    mapping(address vault => uint256) public totalReservedShares;


    error SystemSunset();
    error UnknownVault();
    error InvalidTermDuration();
    error InvalidNumberOfCollaterals();
    error InvalidAsset();
    error InvalidLTV();
    error InvalidEarlyRepayPenalty();
    error InvalidVaultState();
    error InsufficientShares();
    error InsufficientReservedShares();

    function deployBond(DeployBondParams memory p) external returns (address) {
        require(settingMaxTermDuration != 0, SystemSunset());
        require(p.termDuration <= settingMaxTermDuration, InvalidTermDuration());
        require(p.collaterals.length >= 1 && p.collaterals.length <= MAX_COLLATERALS, InvalidNumberOfCollaterals());
        require(p.earlyRepayPenalty <= 1e18, InvalidEarlyRepayPenalty());

        IEulerRouter router = IEulerRouter(IEulerRouterFactory(routerFactory).deploy(address(this)));
        IEVault vault = IEVault(GenericFactory(eVaultFactory).createProxy(address(0), true, abi.encodePacked(p.asset, address(router), p.unitOfAccount)));

        // Install Storage

        uint40 termEnd = uint40(block.timestamp + p.termDuration);

        bondsByVault[address(vault)] = BondState({
            state: BOND_STATE_ACTIVE,
            termEnd: termEnd,
            termStart: uint40(block.timestamp),
            restrictedLender: p.restrictedLender,
            restrictedBorrower: p.restrictedBorrower,
            earlyRepayPenalty: p.earlyRepayPenalty,
            interestRate: p.interestRate,
            reserveMultiplier: settingReserveMultiplier,
            settlementInterestRate: settingSettlementInterestRate,
            nextTransitionTime: termEnd
        });

        activeBonds.add(address(vault));

        // Configure vault

        vault.setInterestRateModel(address(this));
        vault.setInterestFee(settingInterestFee);
        vault.setFeeReceiver(p.interestFeeReceiver);
        vault.setHookConfig(address(this), OP_DEPOSIT | OP_MINT | OP_SKIM | OP_WITHDRAW | OP_REDEEM | OP_TRANSFER | OP_BORROW | OP_REPAY | OP_REPAY_WITH_SHARES | OP_PULL_DEBT | OP_CONVERT_FEES | OP_LIQUIDATE | OP_TOUCH);
        vault.setMaxLiquidationDiscount(0.15e4);
        vault.setLiquidationCoolOffTime(1);
        vault.setCaps(2, 0); // supplyCap is 0, borrowCap is unlimited

        router.govSetResolvedVault(address(vault), true);
        router.govSetConfig(p.asset, p.unitOfAccount, p.oracle);

        for (uint256 i = 0; i < p.collaterals.length; i++) {
            require(p.collaterals[i].asset != address(0), InvalidAsset());

            IEVault collateralVault;

            if (eVaultFactory.isProxy(address(collateralVault))) {
                collateralVault = IEVault(p.collaterals[i].asset);
            } else {
                collateralVault = getEscrowVault(p.collaterals[i].asset);
            }

            router.govSetResolvedVault(address(collateralVault), true);

            uint16 liqLTV = p.collaterals[i].liquidationLTV;
            require(liqLTV > 0.1e4, InvalidLTV());

            router.govSetConfig(collateralVault.asset(), p.unitOfAccount, address(stubOracle));
            vault.setLTV(address(collateralVault), uint16(uint256(liqLTV) * 0.98e18 / 1e18), liqLTV, 0);
            router.govSetConfig(collateralVault.asset(), p.unitOfAccount, p.collaterals[i].oracle);
        }

        // Renounce all governorship

        router.transferGovernance(address(0));
        vault.setGovernorAdmin(address(0));

        return address(vault);
    }



    function _transition(address vault) internal {
        BondState storage b = bondsByVault[vault];
        uint8 state = b.state;
        require(state != 0, UnknownVault());

        if (block.timestamp < b.nextTransitionTime) return;

        if (state == BOND_STATE_ACTIVE) {
            IEVault(vault).setCaps(2, 2); // zero out both caps

            address[] memory collaterals = IEVault(vault).LTVList();

            for (uint256 i = 0; i < collaterals.length; ++i) {
                IEVault(vault).setLTV(collaterals[i], 0, IEVault(vault).LTVLiquidation(collaterals[i]), 0);
            }

            b.nextTransitionTime = uint40(block.timestamp + 3 days);
            b.state = BOND_STATE_SOFT_SETTLEMENT;
        } else if (state == BOND_STATE_SOFT_SETTLEMENT) {
            address[] memory collaterals = IEVault(vault).LTVList();

            for (uint256 i = 0; i < collaterals.length; ++i) {
                IEVault(vault).setLTV(collaterals[i], 0, 0, 3 days);
            }

            b.nextTransitionTime = uint40(block.timestamp + 3 days);
            b.state = BOND_STATE_HARD_SETTLEMENT;
        } else if (state == BOND_STATE_HARD_SETTLEMENT) {
            b.state = BOND_STATE_FINAL;
        }
    }




    function reserve(address bond, uint256 amount, address receiver) external returns (uint256 shares) { // FIXME nonReentrant
        uint8 state = bondsByVault[bond].state;
        require(state != 0, UnknownVault());
        require(state == BOND_STATE_ACTIVE, InvalidVaultState());

        IERC20(IEVault(bond).asset()).safeTransferFrom(_msgSender(), bond, amount);
        shares = IEVault(bond).skim(amount, address(this));

        reservedShares[bond][receiver] += shares;
        totalReservedShares[bond] += shares;
        adjustSupplyCap(bond);
    }

    function unreserve(address bond, uint256 shares, address receiver) external returns (uint256 assets) { // FIXME nonReentrant
        uint8 state = bondsByVault[bond].state;
        require(state != 0, UnknownVault());

        require(reservedShares[bond][_msgSender()] >= shares, InsufficientShares());

        reservedShares[bond][_msgSender()] -= shares;
        totalReservedShares[bond] -= shares;

        assets = IEVault(bond).redeem(shares, receiver, address(this));

        if (state != BOND_STATE_FINAL) {
            // Except when final, reserved shares can only be removed if they aren't covering any senior shares
            uint256 unreservedShares = IEVault(bond).totalSupply() - totalReservedShares[bond];
            require(totalReservedShares[bond] >= unreservedShares, InsufficientReservedShares());

            if (state == BOND_STATE_ACTIVE) adjustSupplyCap(bond);
        }
    }

    function adjustSupplyCap(address bond) internal {
        uint256 newReserved = IEVault(bond).convertToAssets(totalReservedShares[bond]);
        uint256 newCap = newReserved * bondsByVault[bond].reserveMultiplier / 1e4;

        IEVault(bond).setCaps(newCap.to_dfloat16(), 0);
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







    function computeInterestRate(address vault, uint256 cash, uint256 borrows) external view returns (uint256) {
        return computeInterestRateView(vault, cash, borrows);
    }

    function computeInterestRateView(address vault, uint256, uint256) public view returns (uint256) {
        BondState storage b = bondsByVault[vault];
        uint8 state = b.state;
        require(state != 0, UnknownVault());

        if (state == 1) return b.interestRate;
        else return b.settlementInterestRate;
    }


    function isHookTarget() external view returns (bytes4) {
        require(bondsByVault[msg.sender].state != 0, UnknownVault());
        return this.isHookTarget.selector;
    }

    /// @dev Extracts original msg.sender from trailing calldata. Can only be used within a hook invoked by a bond vault.
    function _msgSenderHook() internal view returns (address msgSender) {
        require(bondsByVault[msg.sender].state != 0, UnknownVault());

        assembly {
            msgSender := shr(96, calldataload(sub(calldatasize(), 20)))
        }
    }

    // Purposes of hooks:
    // * restricted lender/borrowers (including pullDebt)
    // * reserves enforcement (including convertFees)
    // * history tracking
    // * state transitions: not possible because reentrancy?

    // OP_DEPOSIT | OP_MINT | OP_SKIM | OP_WITHDRAW | OP_REDEEM | OP_TRANSFER | OP_BORROW | OP_REPAY | OP_REPAY_WITH_SHARES | OP_PULL_DEBT | OP_CONVERT_FEES | OP_LIQUIDATE | OP_TOUCH

    function deposit(uint256 amount, address receiver) external {
    }
}
