// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/console.sol"; //FIXME

import {EnumerableSet} from "openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {EVCUtil} from "evc/utils/EVCUtil.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import "evk/EVault/shared/Constants.sol";

import {IEulerRouterFactory, IEulerRouter} from "./interfaces/Misc.sol";
import {StubOracle} from "./StubOracle.sol";
import "./DFloat16.sol";


contract LayerCredit is EVCUtil {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;
    using DFloat16 for uint256;

    GenericFactory immutable private eVaultFactory;
    IEulerRouterFactory immutable private routerFactory;
    StubOracle immutable private stubOracle; // FIXME: do we want to support pull oracles?

    uint256 private constant MAX_COLLATERALS = 3;

    address public settingAdmin;
    uint40 public settingMaxTermDuration = 90 days; // Special value of 0 means system sunset (no new bond creation allowed)
    uint16 public settingInterestFee = 0.1e4;
    uint40 public settingReserveMultiplier = 20e4; // 1e4 scale
    uint80 public settingSettlementInterestRate = 21964959992727444861; // 100% APY
    bool locked;

    mapping(address asset => address escrowVault) public escrowVaults;

    constructor(address evc, address eVaultFactory_, address routerFactory_, address settingAdmin_) EVCUtil(evc) {
        eVaultFactory = GenericFactory(eVaultFactory_);
        routerFactory = IEulerRouterFactory(routerFactory_);
        stubOracle = new StubOracle();

        settingAdmin = settingAdmin_;
    }

    error Reentrancy();
    modifier nonReentrant() {
        require(locked == false, Reentrancy());
        locked = true;

        _;

        locked = false;
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

    function deployBond(DeployBondParams memory p) external nonReentrant returns (address) {
        require(settingMaxTermDuration != 0, SystemSunset());
        require(p.termDuration <= settingMaxTermDuration, InvalidTermDuration());
        require(p.collaterals.length >= 1 && p.collaterals.length <= MAX_COLLATERALS, InvalidNumberOfCollaterals());
        require(p.earlyRepayPenalty <= 1e18, InvalidEarlyRepayPenalty());

        IEulerRouter router = IEulerRouter(IEulerRouterFactory(routerFactory).deploy(address(this)));
        IEVault vault = IEVault(GenericFactory(eVaultFactory).createProxy(address(0), false, abi.encodePacked(p.asset, address(router), p.unitOfAccount)));

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
        vault.setHookConfig(address(this), OP_DEPOSIT | OP_MINT | OP_SKIM | OP_WITHDRAW | OP_REDEEM | OP_TRANSFER | OP_BORROW | OP_REPAY | OP_REPAY_WITH_SHARES | OP_PULL_DEBT | OP_CONVERT_FEES | OP_LIQUIDATE);
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

        // Renounce router governorship

        router.transferGovernance(address(0));

        _addToHistory(HISTORY_ACTION_BONDDEPLOY, address(vault), address(0), 0);

        return address(vault);
    }



    function transition(address bond) external nonReentrant {
        _transition(bond);
    }

    function _transition(address bond) internal {
        BondState storage b = bondsByVault[bond];
        uint8 state = b.state;
        require(state != 0, UnknownVault());

        if (block.timestamp < b.nextTransitionTime || state == BOND_STATE_FINAL) return;

        if (state == BOND_STATE_ACTIVE) {
            IEVault(bond).setCaps(2, 2); // zero out both caps

            address[] memory collaterals = IEVault(bond).LTVList();

            for (uint256 i = 0; i < collaterals.length; ++i) {
                IEVault(bond).setLTV(collaterals[i], 0, IEVault(bond).LTVLiquidation(collaterals[i]), 0);
            }

            b.nextTransitionTime = uint40(block.timestamp + 3 days);
            b.state = BOND_STATE_SOFT_SETTLEMENT;
        } else if (state == BOND_STATE_SOFT_SETTLEMENT) {
            address[] memory collaterals = IEVault(bond).LTVList();

            for (uint256 i = 0; i < collaterals.length; ++i) {
                IEVault(bond).setLTV(collaterals[i], 0, 0, 3 days);
            }

            b.nextTransitionTime = uint40(block.timestamp + 3 days);
            b.state = BOND_STATE_HARD_SETTLEMENT;
        } else if (state == BOND_STATE_HARD_SETTLEMENT) {
            b.state = BOND_STATE_FINAL;
        }

        _addToHistory(HISTORY_ACTION_TRANSITION, bond, address(0), b.state);
    }




    function reserve(address bond, uint256 amount, address receiver) external callThroughEVC nonReentrant returns (uint256 shares) {
        uint8 state = bondsByVault[bond].state;
        require(state != 0, UnknownVault());
        require(state == BOND_STATE_ACTIVE, InvalidVaultState());

        _enforceRestrictedLender(bond, receiver);

        IERC20(IEVault(bond).asset()).safeTransferFrom(_msgSender(), bond, amount);
        shares = IEVault(bond).skim(amount, address(this));

        reservedShares[bond][receiver] += shares;
        totalReservedShares[bond] += shares;
        adjustSupplyCap(bond);

        _addToHistory(HISTORY_ACTION_RESERVE, bond, receiver, amount.to_dfloat16());
    }

    function unreserve(address bond, uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        uint8 state = bondsByVault[bond].state;
        require(state != 0, UnknownVault());

        require(reservedShares[bond][_msgSender()] >= shares, InsufficientShares());

        reservedShares[bond][_msgSender()] -= shares;
        totalReservedShares[bond] -= shares;

        // FIXME: make sure receiver is an owner account (or does redeem() do this already?)
        assets = IEVault(bond).redeem(shares, receiver, address(this));

        if (state != BOND_STATE_FINAL) {
            // Except when final, reserved shares can only be removed if they aren't covering any senior shares
            uint256 unreservedShares = IEVault(bond).totalSupply() - totalReservedShares[bond];
            require(totalReservedShares[bond] >= unreservedShares, InsufficientReservedShares());

            if (state == BOND_STATE_ACTIVE) adjustSupplyCap(bond);
        }

        _addToHistory(HISTORY_ACTION_UNRESERVE, bond, _msgSender(), IEVault(bond).convertToAssets(shares).to_dfloat16());
    }

    function adjustSupplyCap(address bond) internal {
        uint256 newReserved = IEVault(bond).convertToAssets(totalReservedShares[bond]);
        uint256 newCap = newReserved * bondsByVault[bond].reserveMultiplier / 1e4;

        IEVault(bond).setCaps(newCap.to_dfloat16(), 0);
    }







    function getEscrowVault(address asset) internal returns (IEVault) {
        if (escrowVaults[asset] != address(0)) return IEVault(escrowVaults[asset]);

        IEVault newEscrow = IEVault(GenericFactory(eVaultFactory).createProxy(address(0), false, abi.encodePacked(asset, address(0), address(0))));
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

    function getSettlingBonds(uint256 start, uint256 end) external view returns (address[] memory) {
        return getSlice(settlingBonds, start, end);
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





    // History layout:
    // [action: 1] [bondId: 5] [whoId: 5] [timestamp: 5] [block: 5] [metadata: 11]

    uint64 public historyLength;
    uint40 private nextHistEntityId = 1;
    uint256[9223372036854775807] private history;

    struct HistEntity {
        address entity;
        uint64 nextIndexEntry;
        uint64[9223372036854775807] index;
    }

    mapping(uint40 id => HistEntity) private histEntities;
    mapping(address entity => uint40 id) private histEntityLookup;

    uint8 internal constant HISTORY_ACTION_DEPOSIT = 1;
    uint8 internal constant HISTORY_ACTION_WITHDRAW = 2;
    uint8 internal constant HISTORY_ACTION_BORROW = 3;
    uint8 internal constant HISTORY_ACTION_REPAY = 4;
    uint8 internal constant HISTORY_ACTION_CONVERTFEES = 5;
    uint8 internal constant HISTORY_ACTION_LIQUIDATE = 6;
    uint8 internal constant HISTORY_ACTION_BONDDEPLOY = 100;
    uint8 internal constant HISTORY_ACTION_TRANSITION = 101;
    uint8 internal constant HISTORY_ACTION_RESERVE = 102;
    uint8 internal constant HISTORY_ACTION_UNRESERVE = 103;

    error MetadataTooBig();

    function _histEntity(address a) internal returns (uint40 id) {
        if (a == address(0)) return 0;

        id = histEntityLookup[a];
        if (id != 0) return id;

        id = nextHistEntityId++;
        histEntities[id].entity = a;
        histEntityLookup[a] = id;
    }

    function _histWriteIndex(uint40 entity, uint64 histLoc) internal {
        if (entity == 0) return;
        uint64 indexLoc = histEntities[entity].nextIndexEntry++;
        histEntities[entity].index[indexLoc] = histLoc;
    }

    function _addToHistory(uint8 action, address bond, address who, uint256 metadata, address extra) internal {
        require(metadata < type(uint88).max, MetadataTooBig());

        uint40 bondEntity = _histEntity(bond);
        uint40 whoEntity = _histEntity(who);
        uint40 extraEntity = _histEntity(extra);

        uint256 h = action;
        h = (h << 40) | bondEntity;
        h = (h << 40) | whoEntity;
        h = (h << 40) | uint40(block.timestamp);
        h = (h << 40) | uint40(block.number);
        h = (h << 88) | metadata;

        uint64 histLoc = historyLength++;

        history[histLoc] = h;
        _histWriteIndex(bondEntity, histLoc);
        _histWriteIndex(whoEntity, histLoc);
        _histWriteIndex(extraEntity, histLoc);
    }

    function _addToHistory(uint8 action, address bond, address who, uint256 metadata) internal {
        _addToHistory(action, bond, who, metadata, address(0));
    }

    function getHistEntityById(uint40 entityId) external view returns (address) {
        return histEntities[entityId].entity;
    }

    function getHistEntityLength(address entity) external view returns (uint256) {
        return histEntities[histEntityLookup[entity]].nextIndexEntry;
    }

    function getHistoryGlobal(uint256 start, uint256 end) external view returns (uint256[] memory) {
        if (end == type(uint256).max) end = historyLength;
        if (end < start || end > historyLength) revert SliceOutOfBounds();

        uint256[] memory slice = new uint256[](end - start);
        for (uint256 i; i < end - start; ++i) {
            slice[i] = history[start + i];
        }

        return slice;
    }

    function getHistoryForEntity(address entity, uint256 start, uint256 end) external view returns (uint256[] memory) {
        HistEntity storage ent = histEntities[histEntityLookup[entity]];

        if (end == type(uint256).max) end = ent.nextIndexEntry;
        if (end < start || end > ent.nextIndexEntry) revert SliceOutOfBounds();

        uint256[] memory slice = new uint256[](end - start);
        for (uint256 i; i < end - start; ++i) {
            slice[i] = history[ent.index[start + i]];
        }

        return slice;
    }






    function isSameAccount(address a, address b) internal pure returns (bool) {
        return (uint160(a) >> 8) == (uint160(b) >> 8);
    }

    error RestrictedLender();
    error RestrictedBorrower();

    function _enforceRestrictedLender(address bond, address who) internal view {
        address restrictedLender = bondsByVault[bond].restrictedLender;
        require(restrictedLender == address(0) || isSameAccount(who, restrictedLender), RestrictedLender());
    }

    function _enforceRestrictedBorrower(address bond, address who) internal view {
        address restrictedBorrower = bondsByVault[bond].restrictedBorrower;
        require(restrictedBorrower == address(0) || isSameAccount(who, restrictedBorrower), RestrictedBorrower());
    }








    // Purposes of hooks:
    // * enforce restricted lender/borrowers (including pullDebt, but not transfers)
    // * ensure operations can't happen after transition times
    // * history tracking

    function isHookTarget() external view returns (bytes4) {
        require(bondsByVault[msg.sender].state != 0, UnknownVault());
        return this.isHookTarget.selector;
    }

    error TransitionRequired();

    /// @dev Extracts original msg.sender from trailing calldata. Can only be used within a hook invoked by a bond vault.
    function hookInfo() internal view returns (address bond, address msgSender) {
        uint8 state = bondsByVault[msg.sender].state;
        require(state != 0, UnknownVault());
        require(block.timestamp < bondsByVault[msg.sender].nextTransitionTime || state == BOND_STATE_FINAL, TransitionRequired());

        assembly {
            msgSender := shr(96, calldataload(sub(calldatasize(), 20)))
        }

        bond = msg.sender;
    }

    function deposit(uint256 amount, address receiver) external {
        (address bond,) = hookInfo();
        _enforceRestrictedLender(bond, receiver);
        _addToHistory(HISTORY_ACTION_DEPOSIT, bond, receiver, amount.to_dfloat16());
    }

    function mint(uint256 shares, address receiver) external {
        (address bond,) = hookInfo();
        _enforceRestrictedLender(bond, receiver);
        _addToHistory(HISTORY_ACTION_DEPOSIT, bond, receiver, IEVault(bond).convertToAssets(shares).to_dfloat16());
    }

    function skim(uint256 amount, address receiver) external {
        (address bond, address msgSender) = hookInfo();
        _enforceRestrictedLender(bond, receiver);
        // Avoid duplicate logs for reserve()
        if (msgSender != address(this)) _addToHistory(HISTORY_ACTION_DEPOSIT, bond, receiver, amount.to_dfloat16());
    }

    function withdraw(uint256 amount, address, address owner) external {
        (address bond,) = hookInfo();
        _addToHistory(HISTORY_ACTION_WITHDRAW, bond, owner, amount.to_dfloat16());
    }

    function redeem(uint256 shares, address, address owner) external {
        (address bond, address msgSender) = hookInfo();
        // Avoid duplicate logs for unreserve()
        if (msgSender != address(this)) _addToHistory(HISTORY_ACTION_WITHDRAW, bond, owner, IEVault(bond).convertToAssets(shares).to_dfloat16());
    }

    function _transferInternal(address bond, address from, address to, uint256 amount) internal {
        uint16 amountCompressed = amount.to_dfloat16();
        _addToHistory(HISTORY_ACTION_WITHDRAW, bond, from, amountCompressed);
        _addToHistory(HISTORY_ACTION_DEPOSIT, bond, to, amountCompressed);
    }

    function transfer(address to, uint256 amount) external {
        (address bond, address msgSender) = hookInfo();
        _transferInternal(bond, msgSender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        (address bond,) = hookInfo();
        _transferInternal(bond, from, to, amount);
    }

    function transferFromMax(address from, address to) external {
        (address bond,) = hookInfo();
        _transferInternal(bond, from, to, IEVault(bond).convertToAssets(IEVault(bond).balanceOf(from)));
    }

    function borrow(uint256 amount, address) external {
        (address bond, address msgSender) = hookInfo();
        _enforceRestrictedBorrower(bond, msgSender);
        _addToHistory(HISTORY_ACTION_BORROW, bond, msgSender, amount.to_dfloat16());
    }

    function repay(uint256 amount, address receiver) external {
        (address bond,) = hookInfo();
        // FIXME: collect early repay penalty
        _addToHistory(HISTORY_ACTION_REPAY, bond, receiver, amount.to_dfloat16());
    }

    function repayWithShares(uint256 amount, address receiver) external {
        (address bond, address msgSender) = hookInfo();
        uint16 amountCompressed = amount.to_dfloat16();
        // FIXME: collect early repay penalty
        _addToHistory(HISTORY_ACTION_WITHDRAW, bond, msgSender, amountCompressed);
        _addToHistory(HISTORY_ACTION_REPAY, bond, receiver, amountCompressed);
    }

    function pullDebt(uint256 amount, address from) external {
        (address bond, address msgSender) = hookInfo();
        _enforceRestrictedBorrower(bond, msgSender);
        uint16 amountCompressed = amount.to_dfloat16();
        _addToHistory(HISTORY_ACTION_REPAY, bond, from, amountCompressed);
        _addToHistory(HISTORY_ACTION_BORROW, bond, msgSender, amountCompressed);
    }

    function convertFees() external {
        (address bond,) = hookInfo();
        _addToHistory(HISTORY_ACTION_CONVERTFEES, bond, address(0), 0);
    }

    function liquidate(address violator, address, uint256 repayAssets, uint256) external {
        (address bond, address msgSender) = hookInfo();
        uint16 amountCompressed = repayAssets.to_dfloat16();
        _addToHistory(HISTORY_ACTION_LIQUIDATE, bond, violator, amountCompressed, msgSender);
        _addToHistory(HISTORY_ACTION_REPAY, bond, violator, amountCompressed);
        _addToHistory(HISTORY_ACTION_BORROW, bond, msgSender, amountCompressed);
    }
}
