// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

interface IEulerRouterFactory {
    function deploy(address governor) external returns (address);
}

interface IEulerRouter {
    function getQuote(uint256 inAmount, address base, address quote) external view returns (uint256);
    function govSetConfig(address base, address quote, address oracle) external;
    function govSetFallbackOracle(address _fallbackOracle) external;
    function govSetResolvedVault(address vault, bool set) external;
    function transferGovernance(address newGovernor) external;
}
