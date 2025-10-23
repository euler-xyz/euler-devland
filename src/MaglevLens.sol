// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEVault, IERC20, IRiskManager} from "evk/EVault/IEVault.sol";
import {RPow} from "evk/EVault/shared/lib/RPow.sol";
import {IEulerSwapRegistry} from "euler-swap/interfaces/IEulerSwapRegistry.sol";
import {IEulerSwap} from "euler-swap/interfaces/IEulerSwap.sol";

contract MaglevLens {
    //// Vault queries

    /// @dev Packed output: underlying asset (address), decimals (uint8), symbol (variable)
    function vaultsStatic(address[] calldata vaults) external view returns (bytes[] memory output) {
        unchecked {
            output = new bytes[](vaults.length);
            for (uint256 i; i < vaults.length; ++i) {
                IEVault v = IEVault(vaults[i]);
                output[i] = abi.encodePacked(v.asset(), v.decimals(), v.symbol());
            }
        }
    }

    struct VaultGlobal {
        uint256 packed1; // cash, borrows, supply cap, borrow cap
        uint256 packed2; // shares, supply APY, borrow APY
    }

    function vaultsGlobal(address[] calldata vaults) external view returns (VaultGlobal[] memory output) {
        unchecked {
            output = new VaultGlobal[](vaults.length);

            for (uint256 i; i < vaults.length; ++i) {
                IEVault v = IEVault(vaults[i]);

                uint256 cash = v.cash();
                uint256 borrows = v.totalBorrows();

                (uint256 borrowAPY, uint256 supplyAPY) = _computeAPYs(v.interestRate(), cash, borrows, v.interestFee());
                (uint16 supplyCap, uint16 borrowCap) = v.caps();

                output[i].packed1 = (cash << (112 + 16 + 16)) | (borrows << (16 + 16)) | (supplyCap << 16) | borrowCap;
                output[i].packed2 = (v.totalSupply() << (48 + 48)) | (supplyAPY << 48) | borrowAPY;
            }
        }
    }

    struct VaultDetailed {
        // IGovernance
        address governorAdmin;
        address feeReceiver;
        uint16 interestFee;
        address interestRateModel;
        uint256 protocolFeeShare;
        address protocolFeeReceiver;
        uint16 maxLiquidationDiscount;
        uint16 liquidationCoolOffTime;
        address hookTarget;
        uint32 hookedOps;
        uint32 configFlags;
        address unitOfAccount;
        address oracle;
        // IBorrowing
        address dToken;
        // IVault
        uint256 accumulatedFees;
        address creator;
    }

    function vaultsDetailed(address[] calldata vaults) external view returns (VaultDetailed[] memory output) {
        unchecked {
            output = new VaultDetailed[](vaults.length);

            for (uint256 i; i < vaults.length; ++i) {
                IEVault v = IEVault(vaults[i]);
                VaultDetailed memory o = output[i];

                o.governorAdmin = v.governorAdmin();
                o.feeReceiver = v.feeReceiver();
                o.interestFee = v.interestFee();
                o.interestRateModel = v.interestRateModel();
                o.protocolFeeShare = v.protocolFeeShare();
                o.protocolFeeReceiver = v.protocolFeeReceiver();
                o.maxLiquidationDiscount = v.maxLiquidationDiscount();
                o.liquidationCoolOffTime = v.liquidationCoolOffTime();
                (o.hookTarget, o.hookedOps) = v.hookConfig();
                o.configFlags = v.configFlags();
                o.unitOfAccount = v.unitOfAccount();
                o.oracle = v.oracle();

                o.dToken = v.dToken();

                o.accumulatedFees = v.accumulatedFees();
                o.creator = v.creator();
            }
        }
    }

    struct VaultPersonalState {
        uint256 packed;
    }

    function vaultsPersonalState(address evc, address me, uint256 subAccountBitmask, address[] calldata vaults)
        external
        view
        returns (VaultPersonalState[] memory output)
    {
        unchecked {
            uint256 numAccounts;
            for (uint256 b = subAccountBitmask; b != 0; b >>= 1) {
                if (b & 1 != 0) numAccounts++;
            }

            output = new VaultPersonalState[](numAccounts * vaults.length);

            uint256 currAccount;
            for (uint256 i;; ++i) {
                if (subAccountBitmask & (1 << i) == 0) continue;

                address a = address(uint160(uint256(uint160(me)) ^ i));

                for (uint256 j; j < vaults.length; ++j) {
                    IEVault v = IEVault(vaults[j]);

                    uint256 index = (currAccount * vaults.length) + j;
                    uint256 flags = (IEVC(evc).isCollateralEnabled(a, address(v)) ? 1 : 0)
                        | (IEVC(evc).isControllerEnabled(a, address(v)) ? 2 : 0);
                    output[index].packed = (flags << 224) | (v.balanceOf(a) << 112) | v.debtOf(a);
                }

                if (++currAccount >= numAccounts) break;
            }
        }
    }

    function myEnteredMarkets(address evc, address me)
        external
        view
        returns (address[] memory collaterals, address[] memory controllers)
    {
        collaterals = IEVC(evc).getCollaterals(me);
        controllers = IEVC(evc).getControllers(me);
    }

    uint256 internal constant SECONDS_PER_YEAR = 365.2425 * 86400;

    function _computeAPYs(uint256 borrowSPY, uint256 cash, uint256 borrows, uint256 interestFee)
        internal
        pure
        returns (uint256 borrowAPY, uint256 supplyAPY)
    {
        unchecked {
            uint256 totalAssets = cash + borrows;
            bool overflow;

            (borrowAPY, overflow) = RPow.rpow(borrowSPY + 1e27, SECONDS_PER_YEAR, 1e27);

            if (overflow) return (0, 0);

            borrowAPY -= 1e27;
            supplyAPY = totalAssets == 0 ? 0 : borrowAPY * borrows * (1e4 - interestFee) / totalAssets / 1e4;

            borrowAPY /= 1e18;
            supplyAPY /= 1e18;
        }
    }

    function getLTVMatrix(address[] calldata vaults, bool liquidationLtv)
        external
        view
        returns (uint16[] memory ltvs)
    {
        unchecked {
            uint256 num = vaults.length;
            ltvs = new uint16[](num * num);

            for (uint256 i = 0; i < num; ++i) {
                address collateralVault = vaults[i];

                for (uint256 j = 0; j < num; ++j) {
                    if (i == j) continue;
                    IEVault debtVault = IEVault(vaults[j]);
                    ltvs[(i * num) + j] = liquidationLtv
                        ? debtVault.LTVLiquidation(collateralVault)
                        : debtVault.LTVBorrow(collateralVault);
                }
            }
        }
    }

    //// EulerSwap queries

    struct EulerSwapData {
        address addr;
        IEulerSwap.StaticParams sParams;
        IEulerSwap.DynamicParams dParams;
        address asset0;
        address asset1;
        uint256 reserve0;
        uint256 reserve1;
        uint256 inLimit01;
        uint256 outLimit01;
        uint256 inLimit10;
        uint256 outLimit10;
    }

    function getEulerSwapData(address poolAddr) internal view returns (EulerSwapData memory output) {
        IEulerSwap pool = IEulerSwap(poolAddr);
        output.addr = poolAddr;
        output.sParams = pool.getStaticParams();
        output.dParams = pool.getDynamicParams();
        {
            (uint112 reserve0, uint112 reserve1,) = pool.getReserves();
            output.reserve0 = reserve0;
            output.reserve1 = reserve1;
        }
        (address asset0, address asset1) = pool.getAssets();
        output.asset0 = asset0;
        output.asset1 = asset1;
        (output.inLimit01, output.outLimit01) = pool.getLimits(asset0, asset1);
        (output.inLimit10, output.outLimit10) = pool.getLimits(asset1, asset0);
    }

    function getMyEulerSwap(address eulerSwapRegistry, address me)
        external
        view
        returns (EulerSwapData memory output)
    {
        address poolAddr = IEulerSwapRegistry(eulerSwapRegistry).poolByEulerAccount(me);
        if (poolAddr != address(0)) output = getEulerSwapData(poolAddr);
    }

    function getEulerSwaps(address eulerSwapRegistry) external view returns (EulerSwapData[] memory output) {
        address[] memory addrs = IEulerSwapRegistry(eulerSwapRegistry).pools();

        output = new EulerSwapData[](addrs.length);

        for (uint256 i = 0; i < addrs.length; ++i) {
            output[i] = getEulerSwapData(addrs[i]);
        }
    }

    function eulerSwapQuoteMulti(
        address[] memory eulerSwaps,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bool exactIn
    ) external view returns (uint256[] memory quotes) {
        quotes = new uint256[](eulerSwaps.length);

        for (uint256 i = 0; i < eulerSwaps.length; ++i) {
            try IEulerSwap(eulerSwaps[i]).computeQuote(tokenIn, tokenOut, amount, exactIn) returns (uint256 q) {
                quotes[i] = q;
            } catch {}
        }
    }

    error AssertEulerSwapReservesFailure();

    function assertEulerSwapReserves(
        address eulerSwap,
        uint112 reserve0Min,
        uint112 reserve0Max,
        uint112 reserve1Min,
        uint112 reserve1Max
    ) external view {
        (uint112 reserve0, uint112 reserve1,) = IEulerSwap(eulerSwap).getReserves();
        require(reserve0 >= reserve0Min && reserve0 <= reserve0Max, AssertEulerSwapReservesFailure());
        require(reserve1 >= reserve1Min && reserve1 <= reserve1Max, AssertEulerSwapReservesFailure());
    }

    //// Liquidity Queries

    error MultipleControllers();

    /// Packed health score: controller (address), subAccount (uint8), health (uint32), error (bool)
    /// @dev Health scores are 1e6 scale.
    function getHealthScores(address evc, address[] calldata addrs) external view returns (uint256[] memory healths) {
        healths = new uint256[](addrs.length);

        for (uint256 i = 0; i < addrs.length; ++i) {
            address addr = addrs[i];

            address controller;
            uint8 subAccountId;
            uint32 health;
            uint8 errorFlag;

            subAccountId = uint8((uint160(IEVC(evc).getAccountOwner(addr)) ^ uint160(addr)) & 0xFF);

            {
                address[] memory controllers = IEVC(evc).getControllers(addr);
                require(controllers.length < 2, MultipleControllers());
                if (controllers.length == 1) controller = controllers[0];
            }

            if (controller != address(0)) {
                (bool success, bytes memory data) =
                    controller.staticcall(abi.encodeCall(IRiskManager.accountLiquidity, (addr, true)));

                if (success) {
                    (uint256 collateralValue, uint256 liabilityValue) = abi.decode(data, (uint256, uint256));

                    if (liabilityValue == 0) {
                        health = type(uint32).max;
                    } else {
                        uint256 h = 1e6 * collateralValue / liabilityValue;
                        if (h > type(uint32).max) h = type(uint32).max;
                        health = uint32(h);
                    }
                } else {
                    errorFlag = 1;
                }
            }

            uint256 o = uint160(controller);
            o = (o << 8) | subAccountId;
            o = (o << 32) | health;
            o = (o << 8) | errorFlag;
            healths[i] = o;
        }
    }
}
