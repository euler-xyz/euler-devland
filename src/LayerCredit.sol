// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {EnumerableSet} from "openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {EVCUtil} from "evc/utils/EVCUtil.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import "evk/EVault/shared/Constants.sol";
import {RPow} from "evk/EVault/shared/lib/RPow.sol";

import {IEulerRouterFactory, IEulerRouter} from "./interfaces/Misc.sol";
import "./DFloat16.sol";


contract LayerCredit is EVCUtil {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;
    using DFloat16 for uint256;

    GenericFactory immutable private eVaultFactory;
    IEulerRouterFactory immutable private routerFactory;
    address immutable private originalFactoryImplementation;

    uint256 private constant MAX_COLLATERALS = 3;
    uint256 private constant MAX_TERM_DURATION = 731 days; // 2 non-leap years plus a day
    uint256 private constant SETTLEMENT_PERIOD = 3 days;
    uint32 private constant LTV_RAMP_DOWN_PERIOD = 3 days;

    bool locked;

    mapping(address asset => address escrowVault) public escrowVaults;

    constructor(address evc, address eVaultFactory_, address routerFactory_) EVCUtil(evc) {
        eVaultFactory = GenericFactory(eVaultFactory_);
        routerFactory = IEulerRouterFactory(routerFactory_);
        originalFactoryImplementation = eVaultFactory.implementation();
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

        address lender;
        address borrower;
        uint80 interestRate;
        uint64 earlyRepayPenalty;
        address penaltyReceiver;

        DeployBondCollateral[] collaterals;
    }


    uint8 internal constant BOND_STATE_ACTIVE = 1;
    uint8 internal constant BOND_STATE_SETTLEMENT = 2;
    uint8 internal constant BOND_STATE_FINAL = 3;

    struct BondState {
        uint8 state;
        uint40 termEnd;
        uint40 termStart;
        address lender;
        address borrower;
        uint80 interestRate;
        uint40 nextTransitionTime;
        uint64 earlyRepayPenalty;
        address penaltyReceiver;
    }

    mapping(address vault => BondState) private bondsByVault;
    EnumerableSet.AddressSet private activeBonds;
    EnumerableSet.AddressSet private settlingBonds;
    address[] private inactiveBonds;


    error FactoryImplementationChanged();
    error UnknownVault();
    error InvalidTermDuration();
    error InvalidNumberOfCollaterals();
    error InvalidAsset();
    error InvalidLTV();
    error InvalidEarlyRepayPenalty();
    error InvalidVaultState();
    error InsufficientShares();
    error ReservedSharesLocked();

    function deployBond(DeployBondParams memory p) external nonReentrant returns (address) {
        require(originalFactoryImplementation == eVaultFactory.implementation(), FactoryImplementationChanged());
        require(p.termDuration <= MAX_TERM_DURATION, InvalidTermDuration());
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
            lender: p.lender,
            borrower: p.borrower,
            interestRate: p.interestRate,
            nextTransitionTime: termEnd,
            earlyRepayPenalty: p.earlyRepayPenalty,
            penaltyReceiver: p.penaltyReceiver
        });

        activeBonds.add(address(vault));

        // Configure vault

        vault.setInterestRateModel(address(this));
        vault.setHookConfig(address(this), OP_DEPOSIT | OP_MINT | OP_SKIM | OP_WITHDRAW | OP_REDEEM | OP_TRANSFER | OP_BORROW | OP_REPAY | OP_REPAY_WITH_SHARES | OP_PULL_DEBT | OP_CONVERT_FEES | OP_LIQUIDATE);
        vault.setMaxLiquidationDiscount(0.15e4);
        vault.setLiquidationCoolOffTime(1);

        router.govSetResolvedVault(address(vault), true);
        router.govSetConfig(p.asset, p.unitOfAccount, p.oracle);

        for (uint256 i = 0; i < p.collaterals.length; i++) {
            require(p.collaterals[i].asset != address(0), InvalidAsset());

            IEVault collateralVault;

            if (eVaultFactory.isProxy(address(p.collaterals[i].asset))) {
                collateralVault = IEVault(p.collaterals[i].asset);
            } else {
                collateralVault = getEscrowVault(p.collaterals[i].asset);
            }

            router.govSetResolvedVault(address(collateralVault), true);

            uint16 liqLTV = p.collaterals[i].liquidationLTV;
            require(liqLTV > 0.1e4, InvalidLTV());

            router.govSetConfig(collateralVault.asset(), p.unitOfAccount, p.collaterals[i].oracle);
            vault.setLTV(address(collateralVault), uint16(uint256(liqLTV) * 0.98e18 / 1e18), liqLTV, 0);
        }

        // Renounce router governorship

        router.transferGovernance(address(0));

        _addToHistory(HISTORY_ACTION_BONDDEPLOY, address(vault), _msgSender(), 0);

        return address(vault);
    }



    function transition(address bond) external nonReentrant {
        BondState storage b = bondsByVault[bond];
        uint8 state = b.state;
        require(state != 0, UnknownVault());

        if (block.timestamp < b.nextTransitionTime || state == BOND_STATE_FINAL) return;

        if (state == BOND_STATE_ACTIVE) {
            b.state = BOND_STATE_SETTLEMENT;
            b.nextTransitionTime = uint40(block.timestamp + SETTLEMENT_PERIOD);

            IEVault(bond).setCaps(2, 2); // zero out both supply and borrow caps

            address[] memory collaterals = IEVault(bond).LTVList();

            for (uint256 i = 0; i < collaterals.length; ++i) {
                IEVault(bond).setLTV(collaterals[i], 0, IEVault(bond).LTVLiquidation(collaterals[i]), 0);
            }
        } else if (state == BOND_STATE_SETTLEMENT) {
            b.state = BOND_STATE_FINAL;

            address[] memory collaterals = IEVault(bond).LTVList();

            for (uint256 i = 0; i < collaterals.length; ++i) {
                IEVault(bond).setLTV(collaterals[i], 0, 0, LTV_RAMP_DOWN_PERIOD);
            }

            IEVault(bond).setGovernorAdmin(address(0));
        }

        _addToHistory(HISTORY_ACTION_TRANSITION, bond, address(0), b.state);

        IEVault(bond).touch(); // update interest rate
    }






    function getEscrowVault(address asset) internal returns (IEVault) {
        if (escrowVaults[asset] != address(0)) return IEVault(escrowVaults[asset]);

        IEVault newEscrow = IEVault(GenericFactory(eVaultFactory).createProxy(address(0), false, abi.encodePacked(asset, address(0), address(0))));
        escrowVaults[asset] = address(newEscrow);

        newEscrow.setHookConfig(address(0), 0);
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

        if (state == BOND_STATE_ACTIVE) {
            return b.interestRate;
        } else if (state == BOND_STATE_SETTLEMENT) {
            return b.interestRate * 3;
        }

        return 0; // Interest stops accruing once FINAL
    }





    // History layout:
    // [action: 1] [bondId: 5] [whoId: 5] [whoSubAccount: 1] [timestamp: 5] [block: 5] [metadata: 10]

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
        require(metadata < type(uint80).max, MetadataTooBig());

        (address whoOwner, uint8 whoSubAccount) = addressToOwner(who);

        uint40 bondEntity = _histEntity(bond);
        uint40 whoEntity = _histEntity(whoOwner);
        uint40 extraEntity = _histEntity(extra);

        uint256 h = action;
        h = (h << 40) | bondEntity;
        h = (h << 40) | whoEntity;
        h = (h << 8) | whoSubAccount;
        h = (h << 40) | uint40(block.timestamp);
        h = (h << 40) | uint40(block.number);
        h = (h << 80) | metadata;

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




    function addressToOwner(address a) internal view returns (address owner, uint8 subAccountId) {
        owner = evc.getAccountOwner(a);
        if (owner == address(0)) owner = a;
        subAccountId = uint8((uint160(a) ^ uint160(owner)) & 0xFF);
    }

    /// @dev Are addresses the same, or sub-accounts of one-another?
    function isSameAccount(address a, address b) internal pure returns (bool) {
        return (uint160(a) >> 8) == (uint160(b) >> 8);
    }

    error LenderRestricted();
    error BorrowerRestricted();

    function _enforceLender(address bond, address who) internal view {
        address lender = bondsByVault[bond].lender;
        require(lender == address(0) || isSameAccount(who, lender), LenderRestricted());
    }

    function _enforceBorrower(address bond, address who) internal view {
        address borrower = bondsByVault[bond].borrower;
        require(borrower == address(0) || isSameAccount(who, borrower), BorrowerRestricted());
    }



    error RepayAmountExceedsDebt();

    function getRepayPenalty(address bond, uint256 amount, address receiver) public view returns (uint256, uint256) {
        BondState storage b = bondsByVault[bond];
        require(b.state != 0, UnknownVault());

        {
            uint256 debt = IEVault(bond).debtOf(receiver);
            if (amount == type(uint256).max) amount = debt;
            require(amount <= debt, RepayAmountExceedsDebt());
        }

        if (b.state != BOND_STATE_ACTIVE || b.earlyRepayPenalty == 0) return (amount, 0);
        require(block.timestamp < b.nextTransitionTime, TransitionRequired());

        uint256 timeRemaining = b.nextTransitionTime - block.timestamp;
        (uint256 multiplier,) = RPow.rpow(b.interestRate + 1e27, timeRemaining, 1e27);
        uint256 interestRemaining = (multiplier - 1e27) * amount / 1e27;

        return (amount, interestRemaining * b.earlyRepayPenalty / 1e18);
    }

    function repayBond(address bond, uint256 amount, address receiver) external nonReentrant returns (uint256, uint256) {
        uint256 penalty;
        (amount, penalty) = getRepayPenalty(bond, amount, receiver);

        IERC20 token = IERC20(IEVault(bond).asset());
        token.safeTransferFrom(_msgSender(), address(this), amount + penalty);
        token.forceApprove(bond, amount + penalty);

        IEVault(bond).repay(amount, receiver);
        token.safeTransfer(bondsByVault[bond].penaltyReceiver, penalty);

        _addToHistory(HISTORY_ACTION_REPAY, bond, receiver, (amount.to_dfloat16() << 16) | penalty.to_dfloat16());

        return (amount, penalty);
    }



    // Purposes of hooks:
    // * enforce restricted lender/borrowers (including pullDebt, but not transfers)
    // * ensure operations can't happen after transition times
    // * history tracking

    function isHookTarget() external view returns (bytes4) {
        require(bondsByVault[msg.sender].state != 0, UnknownVault());
        return this.isHookTarget.selector;
    }

    error DirectRepayNotAllowed();
    error OperationDisabled();
    error TransitionRequired();

    /// @dev Extracts original msg.sender from trailing calldata. Must only be used within a hook invoked by a bond vault.
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
        _enforceLender(bond, receiver);
        _addToHistory(HISTORY_ACTION_DEPOSIT, bond, receiver, amount.to_dfloat16());
    }

    function mint(uint256 shares, address receiver) external {
        (address bond,) = hookInfo();
        _enforceLender(bond, receiver);
        _addToHistory(HISTORY_ACTION_DEPOSIT, bond, receiver, IEVault(bond).convertToAssets(shares).to_dfloat16());
    }

    function skim(uint256 amount, address receiver) external {
        (address bond,) = hookInfo();
        _enforceLender(bond, receiver);
        _addToHistory(HISTORY_ACTION_DEPOSIT, bond, receiver, amount.to_dfloat16());
    }

    function withdraw(uint256 amount, address, address owner) external {
        (address bond,) = hookInfo();
        _addToHistory(HISTORY_ACTION_WITHDRAW, bond, owner, amount.to_dfloat16());
    }

    function redeem(uint256 shares, address, address owner) external {
        (address bond,) = hookInfo();
        _addToHistory(HISTORY_ACTION_WITHDRAW, bond, owner, IEVault(bond).convertToAssets(shares).to_dfloat16());
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
        _enforceBorrower(bond, msgSender);
        _addToHistory(HISTORY_ACTION_BORROW, bond, msgSender, amount.to_dfloat16());
    }

    function repay(uint256, address) external view {
        (, address msgSender) = hookInfo();
        require(msgSender == address(this), DirectRepayNotAllowed());
    }

    function repayWithShares(uint256, address) external pure {
        revert OperationDisabled();
    }

    function pullDebt(uint256 amount, address from) external {
        (address bond, address msgSender) = hookInfo();
        _enforceBorrower(bond, msgSender);
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
