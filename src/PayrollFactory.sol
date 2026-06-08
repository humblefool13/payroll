// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {PayrollPool} from "./PayrollPool.sol";

/// @notice Factory + global registry for the payroll platform.
///         Owner controls the platform fee (charged on all withdrawals/claims)
///         and the token whitelist.
contract PayrollFactory is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error FeeTooHigh();
    error AlreadyWhitelisted();
    error NotAValidPool();
    error OnlyPool();
    error ETHValueMismatch();
    error NothingToCollect();
    error ETHTransferFailed();

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant MAX_FEE_BPS = 100; // 1% hard cap

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice Platform fee in basis points (e.g. 50 = 0.5%).
    uint256 public feeBps;

    /// @notice Whitelisted tokens array
    address[] public whitelistedTokens;

    /// @notice Accumulated fees per token (address(0) = ETH).
    mapping(address token => uint256 amount) public accruedFees;

    /// @notice Token whitelist. address(0) represents native ETH.
    mapping(address token => bool allowed) public tokenWhitelisted;

    /// @notice Source of truth for pool authenticity. Set in deployPool(), never unset.
    mapping(address pool => bool deployed) public isDeployedPool;

    /// @notice Pools where a given address is the admin (owner).
    mapping(address admin => address[] pools) private _adminPools;

    /// @notice Pools where a given address is a beneficiary.
    mapping(address beneficiary => address[] pools) private _beneficiaryPools;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event PoolDeployed(address indexed pool, address indexed admin);
    event FeeBpsSet(uint256 oldFeeBps, uint256 newFeeBps);
    event TokenWhitelisted(address indexed token);
    event FeeCollected(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address initialOwner) Ownable(initialOwner) {
        tokenWhitelisted[address(0)] = true;
        emit TokenWhitelisted(address(0));
    }

    // -------------------------------------------------------------------------
    // Owner functions
    // -------------------------------------------------------------------------

    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit FeeBpsSet(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    /// @notice Add a token to the whitelist. Whitelist is additive-only; never destructive.
    function whitelistToken(address token) external onlyOwner {
        if (tokenWhitelisted[token]) revert AlreadyWhitelisted();
        tokenWhitelisted[token] = true;
        whitelistedTokens.push(token);
        emit TokenWhitelisted(token);
    }

    /// @notice Pull all accrued platform fees for `token` to address `to`.
    function collectFees(
        address token,
        address payable to
    ) external onlyOwner nonReentrant {
        uint256 amount = accruedFees[token];
        if (amount == 0) revert NothingToCollect();
        accruedFees[token] = 0;
        emit FeeCollected(token, to, amount);
        if (token == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // -------------------------------------------------------------------------
    // Pool deployment
    // -------------------------------------------------------------------------

    function deployPool() external returns (address pool) {
        PayrollPool p = new PayrollPool(msg.sender, address(this));
        pool = address(p);
        isDeployedPool[pool] = true;
        _adminPools[msg.sender].push(pool);
        emit PoolDeployed(pool, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Registry hooks — called only by deployed pools
    // -------------------------------------------------------------------------

    /// @notice Register a beneficiary→pool mapping. Called by a pool on first allocation.
    function registerBeneficiary(address beneficiary, address pool) external {
        if (!isDeployedPool[pool]) revert NotAValidPool();
        if (msg.sender != pool) revert OnlyPool();
        _beneficiaryPools[beneficiary].push(pool);
    }

    /// @notice Record a fee accrual from a pool. ETH fees arrive with msg.value.
    function recordFee(address token, uint256 amount) external payable {
        if (!isDeployedPool[msg.sender]) revert NotAValidPool();
        if (token == address(0) && msg.value != amount)
            revert ETHValueMismatch();
        accruedFees[token] += amount;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getAdminPools(
        address admin
    ) external view returns (address[] memory) {
        return _adminPools[admin];
    }

    function getBeneficiaryPools(
        address beneficiary
    ) external view returns (address[] memory) {
        return _beneficiaryPools[beneficiary];
    }

    function getWhitelistedTokens() external view returns (address[] memory) {
        return whitelistedTokens;
    }
}
