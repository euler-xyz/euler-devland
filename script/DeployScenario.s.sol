// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// System

import {Script, console} from "forge-std/Script.sol";

// Deploy base

import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {EulerRouterFactory} from "../src/vendor/EulerRouterFactory/EulerRouterFactory.sol";

import {EVault} from "evk/EVault/EVault.sol";
import {ProtocolConfig} from "evk/ProtocolConfig/ProtocolConfig.sol";

import {Dispatch} from "evk/EVault/Dispatch.sol";

import {Initialize} from "evk/EVault/modules/Initialize.sol";
import {Token} from "evk/EVault/modules/Token.sol";
import {Vault} from "evk/EVault/modules/Vault.sol";
import {Borrowing} from "evk/EVault/modules/Borrowing.sol";
import {Liquidation} from "evk/EVault/modules/Liquidation.sol";
import {BalanceForwarder} from "evk/EVault/modules/BalanceForwarder.sol";
import {Governance} from "evk/EVault/modules/Governance.sol";
import {RiskManager} from "evk/EVault/modules/RiskManager.sol";

import {IEVault, IERC20} from "evk/EVault/IEVault.sol";
import {TypesLib} from "evk/EVault/shared/types/Types.sol";
import {Base} from "evk/EVault/shared/Base.sol";

import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";

import {TestERC20} from "evk-test/mocks/TestERC20.sol";
import {MockBalanceTracker} from "evk-test/mocks/MockBalanceTracker.sol";
import {MockPriceOracle} from "evk-test/mocks/MockPriceOracle.sol";
import {IRMTestDefault} from "evk-test/mocks/IRMTestDefault.sol";
import {IHookTarget} from "evk/interfaces/IHookTarget.sol";
import {SequenceRegistry} from "evk/SequenceRegistry/SequenceRegistry.sol";

struct Asset {
    string symbol;
    uint8 decimals;
    address asset;
    address vault;
    string price;
    uint256 priceNum;
}

contract DeployScenario is Script {
    //////// Users

    uint256 user0PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 user1PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 user2PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 user3PK = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

    address user0 = vm.addr(user0PK);
    address user1 = vm.addr(user1PK);
    address user2 = vm.addr(user2PK);
    address user3 = vm.addr(user3PK);

    //////// Main system

    EthereumVaultConnector public evc;
    address admin;
    address feeReceiver;
    address protocolFeeReceiver;
    ProtocolConfig protocolConfig;
    address balanceTracker;
    MockPriceOracle oracle;
    address unitOfAccount;
    address permit2;
    address sequenceRegistry;
    GenericFactory public factory;
    EulerRouterFactory routerFactory;

    Base.Integrations integrations;
    Dispatch.DeployedModules modules;

    address initializeModule;
    address tokenModule;
    address vaultModule;
    address borrowingModule;
    address liquidationModule;
    address riskManagerModule;
    address balanceForwarderModule;
    address governanceModule;

    //////// Tokens

    Asset[] assets;

    TestERC20 assetWETH;
    IEVault eWETH;

    TestERC20 assetwstETH;
    IEVault ewstETH;

    TestERC20 assetUSDC;
    IEVault eUSDC;

    TestERC20 assetUSDT;
    IEVault eUSDT;

    TestERC20 assetDAI;
    IEVault eDAI;

    TestERC20 assetUSDZ;
    IEVault eUSDZ;

    function run() public {
        vm.startBroadcast(user3PK);

        deployEulerSystem();
        deployAssets();

        vm.stopBroadcast();

        addLiquidity();

        setup();
    }

    function deployEulerSystem() internal {
        admin = makeAddr("admin");
        feeReceiver = makeAddr("feeReceiver");
        protocolFeeReceiver = makeAddr("protocolFeeReceiver");

        evc = new EthereumVaultConnector();
        factory = new GenericFactory(user3);
        routerFactory = new EulerRouterFactory(address(evc));

        protocolConfig = new ProtocolConfig(admin, protocolFeeReceiver);
        balanceTracker = address(new MockBalanceTracker());
        oracle = new MockPriceOracle();
        unitOfAccount = address(840);
        permit2 = address(0);
        sequenceRegistry = address(new SequenceRegistry());
        integrations =
            Base.Integrations(address(evc), address(protocolConfig), sequenceRegistry, balanceTracker, permit2);

        initializeModule = address(new Initialize(integrations));
        tokenModule = address(new Token(integrations));
        vaultModule = address(new Vault(integrations));
        borrowingModule = address(new Borrowing(integrations));
        liquidationModule = address(new Liquidation(integrations));
        riskManagerModule = address(new RiskManager(integrations));
        balanceForwarderModule = address(new BalanceForwarder(integrations));
        governanceModule = address(new Governance(integrations));

        modules = Dispatch.DeployedModules({
            initialize: initializeModule,
            token: tokenModule,
            vault: vaultModule,
            borrowing: borrowingModule,
            liquidation: liquidationModule,
            riskManager: riskManagerModule,
            balanceForwarder: balanceForwarderModule,
            governance: governanceModule
        });

        address evaultImpl = address(new EVault(integrations, modules));

        factory.setImplementation(evaultImpl);

        string memory result = vm.serializeAddress("coreAddresses", "evc", address(evc));
        result = vm.serializeAddress("coreAddresses", "eVaultFactory", address(factory));
        vm.writeJson(result, "./dev-ctx/addresses/31337/CoreAddresses.json");
    }

    function genAsset(string memory symbol, uint8 decimals, string memory price, uint256 priceNum)
        internal
        returns (TestERC20, IEVault)
    {
        Asset memory a;

        a.symbol = symbol;
        a.decimals = decimals;
        a.asset = address(new TestERC20(string(abi.encodePacked(symbol, " Token")), symbol, decimals, false));
        a.vault = factory.createProxy(address(0), true, abi.encodePacked(a.asset, address(oracle), unitOfAccount));
        a.price = price;
        a.priceNum = priceNum;

        IEVault(a.vault).setHookConfig(address(0), 0);
        IEVault(a.vault).setInterestRateModel(address(new IRMTestDefault()));
        IEVault(a.vault).setMaxLiquidationDiscount(0.2e4);
        IEVault(a.vault).setFeeReceiver(feeReceiver);

        assets.push(a);
        return (TestERC20(a.asset), IEVault(a.vault));
    }

    function deployAssets() internal virtual {
        (assetWETH, eWETH) = genAsset("WETH", 18, "2865", 2865e18);
        (assetwstETH, ewstETH) = genAsset("wstETH", 18, "3055", 3055e18);
        (assetUSDC, eUSDC) = genAsset("USDC", 6, "1.000142", 1e18 * 1e12);
        (assetUSDT, eUSDT) = genAsset("USDT", 6, "0.999218", 1e18 * 1e12);
        (assetDAI, eDAI) = genAsset("DAI", 18, "1.00123", 1e18);
        (assetUSDZ, eUSDZ) = genAsset("USDZ", 6, "1.00081", 1e18 * 1e12);

        for (uint256 i; i < assets.length; ++i) {
            oracle.setPrice(assets[i].asset, unitOfAccount, assets[i].priceNum);
            oracle.setPrice(assets[i].vault, unitOfAccount, assets[i].priceNum);

            for (uint256 j; j < assets.length; ++j) {
                if (i == j) continue;
                IEVault(assets[i].vault).setLTV(assets[j].vault, 0.92e4, 0.94e4, 0);
            }
        }

        eWETH.setLTV(address(ewstETH), 0.5e4, 0.52e4, 0); // lower wstETH/WETH LTV for testing
        ewstETH.setLTV(address(eWETH), 0.91e4, 0.93e4, 0); // change WETH/wstETH LTV for testing
        ewstETH.setLTV(address(eUSDC), 0.8e4, 0.82e4, 0); // change USDC/wstETH LTV for testing

        eWETH.setLTV(address(eUSDC), 0.65e4, 0.67e4, 0); // change USDC/WETH LTV for testing
        eWETH.setLTV(address(eUSDT), 0.85e4, 0.87e4, 0); // change USDT/WETH LTV for testing

        address[] memory vaults = new address[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            vaults[i] = assets[i].vault;
        }

        {
            string memory result = vm.serializeAddress("products", "vaults", vaults);
            string memory obj = vm.serializeString("products2", "testing-product", result);
            vm.writeJson(obj, "./dev-ctx/labels/31337/products.json");
        }

        {
            string memory result = vm.serializeAddress("misc", "oracle", address(oracle));
            vm.writeJson(result, "./dev-ctx/misc/31337/misc.json");
        }

        {
            string memory pricesFile = "./dev-ctx/priceapi/31337/prices.json";
            vm.writeLine(pricesFile, "{");

            for (uint256 i; i < assets.length; ++i) {
                string memory line = string(
                    abi.encodePacked(
                        "\"",
                        vm.toString(assets[i].asset),
                        "\": {\"price\":",
                        assets[i].price,
                        "}",
                        (i == assets.length - 1 ? "" : ",")
                    )
                );
                vm.writeLine(pricesFile, line);
            }

            vm.writeLine(pricesFile, "}");
        }

        {
            string memory tokenListFile = "./dev-ctx/tokenlist/31337/tokenList.json";
            vm.writeLine(tokenListFile, "[");

            for (uint256 i; i < assets.length; ++i) {
                vm.writeLine(tokenListFile, "  {");

                vm.writeLine(tokenListFile, "    \"chainId\": 31337,");
                vm.writeLine(tokenListFile, string(abi.encodePacked("    \"address\": \"", vm.toString(assets[i].asset), "\",")));
                vm.writeLine(tokenListFile, string(abi.encodePacked("    \"symbol\": \"", assets[i].symbol, "\",")));
                vm.writeLine(tokenListFile, string(abi.encodePacked("    \"decimals\": ", vm.toString(assets[i].decimals))));

                vm.writeLine(tokenListFile, string(abi.encodePacked("  }", (i == assets.length - 1 ? "" : ","))));
            }

            vm.writeLine(tokenListFile, "]");
        }
    }

    function getSubaccount(address user, uint8 account) internal pure returns (address) {
        return address(uint160(user) ^ account);
    }

    function addLiquidity() internal virtual {
        // user2 is passive depositor
        vm.startBroadcast(user2PK);

        assetUSDC.mint(user2, 1000000e6);
        assetUSDT.mint(user2, 1000000e6);
        assetWETH.mint(user2, 100000e18);
        assetwstETH.mint(user2, 100000e18);
        assetDAI.mint(user2, 1000000e18);
        assetUSDZ.mint(user2, 1000000e6);

        assetUSDC.approve(address(eUSDC), type(uint256).max);
        assetUSDT.approve(address(eUSDT), type(uint256).max);
        assetWETH.approve(address(eWETH), type(uint256).max);
        assetwstETH.approve(address(ewstETH), type(uint256).max);
        assetDAI.approve(address(eDAI), type(uint256).max);
        assetUSDZ.approve(address(eUSDZ), type(uint256).max);

        eUSDC.deposit(1000000e6, user2);
        eUSDT.deposit(1000000e6, user2);
        eWETH.deposit(100000e18, user2);
        ewstETH.deposit(100000e18, user2);
        eDAI.deposit(1000000e18, user2);
        eUSDZ.deposit(1000000e6, user2);

        vm.stopBroadcast();
    }

    function giveLotsOfCash(address user) internal virtual {
        assetUSDC.mint(user, 1000000e6);
        assetUSDT.mint(user, 1000000e6);
        assetWETH.mint(user, 1000e18);
        assetwstETH.mint(user, 1000e18);
        assetDAI.mint(user, 1000000e18);
        assetUSDZ.mint(user, 1000000e18);
    }

    function setup() internal virtual {}
}
