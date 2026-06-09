// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface IPayrollFactory {
    function feeBps() external view returns (uint256);
    function tokenWhitelisted(address token) external view returns (bool);
    function registerBeneficiary(address beneficiary, address pool) external;
    function unregisterBeneficiary(address beneficiary, address pool) external;
    function recordFee(address token, uint256 amount) external payable;
}
