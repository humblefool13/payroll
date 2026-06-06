// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IPayrollFactory} from "./interfaces/IPayrollFactory.sol";

/// @notice A single payroll pool. Deployed by PayrollFactory; owned by the pool admin.
///
/// Allocation model
/// ────────────────
/// Each (beneficiary, token) pair carries an ordered list of Tranches.
/// A tranche represents one rate-period: "amountPerPeriod every periodSeconds,
/// starting at startTime, ending at endTime (0 = still active)."
///
/// When admin edits an allocation the active tranche is sealed at block.timestamp
/// and a new tranche is pushed. Accrual math per tranche:
///
///   accrued = floor((min(endTime, now) - startTime) / periodSeconds) * amountPerPeriod
///
/// Total claimable = sum(accrued over all tranches) - alreadyClaimed
///
/// This guarantees: past unclaimed amounts are never touched by an edit; only
/// periods that fall inside the new tranche use the new rate.
contract PayrollPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error PoolPausedError();
    error PoolClosedError();
    error PoolNotPaused();
    error PoolAlreadyPaused();
    error PoolAlreadyClosed();
    error TokenNotWhitelisted();
    error UseDepositETH();
    error ZeroBeneficiary();
    error InvalidBeneficiary();
    error ZeroAmount();
    error StartTimeInPast();
    error NoAllocation();
    error AllocationAlreadyRemoved();
    error NothingToClaim();
    error PoolUnderfunded();
    error AmountExceedsAvailable();
    error ETHTransferFailed();
    error RenounceOwnershipDisabled();

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    enum Frequency {
        WEEKLY, // 7 days
        MONTHLY, // 30 days
        QUARTERLY // 90 days
    }

    struct Tranche {
        uint256 amountPerPeriod; // in token's smallest unit
        uint256 startTime; // unix timestamp of the first claimable period start
        uint256 periodSeconds; // seconds per period, derived from Frequency at creation
        uint256 endTime; // 0 = still active; set to block.timestamp when superseded/removed
    }

    struct AllocationView {
        address token;
        Frequency frequency;
        uint256 amountPerPeriod;
        uint256 nextClaimTime; // 0 if allocation is inactive
        uint256 pendingAmount;
        bool active;
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    address public immutable factory;

    /// @dev Guards one-time factory registration per beneficiary per pool.
    mapping(address => bool) private _everRegistered;

    /// @dev Tranche history: beneficiary => token => Tranche[].
    ///      Tranches are appended-only; earlier indices are older/sealed.
    mapping(address beneficiary => mapping(address token => Tranche[]))
        private _tranches;

    /// @dev Cumulative amount already paid out per (beneficiary, token).
    mapping(address beneficiary => mapping(address token => uint256 claimed))
        private _claimed;

    /// @dev Ordered list of tokens ever allocated to each beneficiary (for enumeration).
    mapping(address beneficiary => address[]) private _beneficiaryTokens;
    mapping(address beneficiary => mapping(address token => bool))
        private _hasToken;

    /// @dev All beneficiaries ever added (for totalCommitted iteration).
    address[] private _beneficiaries;
    mapping(address => bool) private _isBeneficiary;

    /// @dev Tracked pool balance per token (address(0) = ETH).
    mapping(address token => uint256 balance) public poolBalance;

    bool public paused;
    bool public closed;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Deposited(
        address indexed token,
        address indexed from,
        uint256 amount
    );
    event AdminWithdrew(
        address indexed token,
        address indexed to,
        uint256 net,
        uint256 fee
    );
    event AllocationSet(
        address indexed beneficiary,
        address indexed token,
        uint256 amountPerPeriod,
        uint256 startTime,
        Frequency frequency
    );
    event AllocationRemoved(address indexed beneficiary, address indexed token);
    event Claimed(
        address indexed beneficiary,
        address indexed token,
        uint256 net,
        uint256 fee
    );
    event PoolPausedEvent();
    event PoolUnpausedEvent();
    event PoolClosedEvent();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier notPaused() {
        if (paused) revert PoolPausedError();
        _;
    }

    modifier notClosed() {
        if (closed) revert PoolClosedError();
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address admin, address _factory) Ownable(admin) {
        factory = _factory;
    }

    // -------------------------------------------------------------------------
    // Admin: deposits
    // -------------------------------------------------------------------------

    function depositETH() external payable onlyOwner notClosed nonReentrant {
        if (!IPayrollFactory(factory).tokenWhitelisted(address(0)))
            revert TokenNotWhitelisted();
        poolBalance[address(0)] += msg.value;
        emit Deposited(address(0), msg.sender, msg.value);
    }

    /// @notice Deposit an ERC-20 token. Caller must have approved this contract for `amount`.
    function depositToken(
        address token,
        uint256 amount
    ) external onlyOwner notClosed nonReentrant {
        if (token == address(0)) revert UseDepositETH();
        if (!IPayrollFactory(factory).tokenWhitelisted(token))
            revert TokenNotWhitelisted();
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before; // handles fee-on-transfer
        poolBalance[token] += received;
        emit Deposited(token, msg.sender, received);
    }

    // -------------------------------------------------------------------------
    // Admin: withdrawals
    // -------------------------------------------------------------------------

    function adminWithdraw(
        address token,
        uint256 amount
    ) external onlyOwner nonReentrant {
        uint256 committed = _totalCommitted(token);
        uint256 available = poolBalance[token] > committed
            ? poolBalance[token] - committed
            : 0;
        if (amount > available) revert AmountExceedsAvailable();

        uint256 fee = _calcFee(amount);
        uint256 net = amount - fee;
        poolBalance[token] -= amount;

        emit AdminWithdrew(token, msg.sender, net, fee);
        _sendFee(token, fee);
        _transfer(token, payable(msg.sender), net);
    }

    // -------------------------------------------------------------------------
    // Admin: allocations
    // -------------------------------------------------------------------------

    /// @notice Create or update an allocation for (beneficiary, token).
    ///
    ///         Edit behaviour: the currently active tranche (if any) is sealed at
    ///         block.timestamp, preserving every full period that already elapsed.
    ///         A new tranche opens with the new rate starting at `startTime`.
    ///
    /// @param startTime First period-start timestamp. Must be >= block.timestamp.
    function setAllocation(
        address beneficiary,
        address token,
        uint256 amountPerPeriod,
        Frequency frequency,
        uint256 startTime
    ) external onlyOwner notClosed {
        if (beneficiary == address(0)) revert ZeroBeneficiary();
        if (beneficiary == address(this) || beneficiary == factory)
            revert InvalidBeneficiary();
        if (!IPayrollFactory(factory).tokenWhitelisted(token))
            revert TokenNotWhitelisted();
        if (amountPerPeriod == 0) revert ZeroAmount();
        if (startTime < block.timestamp) revert StartTimeInPast();

        uint256 periodSecs = _periodSeconds(frequency);
        Tranche[] storage tranches = _tranches[beneficiary][token];

        // Seal the active tranche at the current moment.
        // floor((block.timestamp - oldStart) / period) * rate is what's owed from it.
        if (tranches.length > 0 && tranches[tranches.length - 1].endTime == 0) {
            tranches[tranches.length - 1].endTime = block.timestamp;
        }

        tranches.push(
            Tranche({
                amountPerPeriod: amountPerPeriod,
                startTime: startTime,
                periodSeconds: periodSecs,
                endTime: 0
            })
        );

        // One-time registration per beneficiary per pool in the factory registry.
        if (!_everRegistered[beneficiary]) {
            _everRegistered[beneficiary] = true;
            IPayrollFactory(factory).registerBeneficiary(
                beneficiary,
                address(this)
            );
        }
        if (!_isBeneficiary[beneficiary]) {
            _isBeneficiary[beneficiary] = true;
            _beneficiaries.push(beneficiary);
        }
        if (!_hasToken[beneficiary][token]) {
            _hasToken[beneficiary][token] = true;
            _beneficiaryTokens[beneficiary].push(token);
        }

        emit AllocationSet(
            beneficiary,
            token,
            amountPerPeriod,
            startTime,
            frequency
        );
    }

    /// @notice Permanently stop future accrual for (beneficiary, token).
    ///         All already-accrued amounts remain claimable indefinitely.
    function removeAllocation(
        address beneficiary,
        address token
    ) external onlyOwner {
        Tranche[] storage tranches = _tranches[beneficiary][token];
        if (tranches.length == 0) revert NoAllocation();
        uint256 last = tranches.length - 1;
        if (tranches[last].endTime != 0) revert AllocationAlreadyRemoved();
        tranches[last].endTime = block.timestamp;
        emit AllocationRemoved(beneficiary, token);
    }

    // -------------------------------------------------------------------------
    // Beneficiary: claim
    // -------------------------------------------------------------------------

    function claim(address token) external nonReentrant notPaused {
        address beneficiary = msg.sender;
        uint256 claimable = _claimable(beneficiary, token);
        if (claimable == 0) revert NothingToClaim();
        if (poolBalance[token] < claimable) revert PoolUnderfunded();

        // Update state before any external calls (checks-effects-interactions).
        _claimed[beneficiary][token] += claimable;
        poolBalance[token] -= claimable;

        uint256 fee = _calcFee(claimable);
        uint256 net = claimable - fee;

        emit Claimed(beneficiary, token, net, fee);
        _sendFee(token, fee);
        _transfer(token, payable(beneficiary), net);
    }

    // -------------------------------------------------------------------------
    // Admin: pool lifecycle
    // -------------------------------------------------------------------------

    function pausePool() external onlyOwner notClosed {
        if (paused) revert PoolAlreadyPaused();
        paused = true;
        emit PoolPausedEvent();
    }

    function unpausePool() external onlyOwner notClosed {
        if (!paused) revert PoolNotPaused();
        paused = false;
        emit PoolUnpausedEvent();
    }

    /// @notice Permanently close the pool.
    ///         Freezes all active tranches. Admin may still withdraw uncommitted funds.
    ///         Beneficiaries may still claim whatever was accrued up to close time.
    ///         Auto-unpauses so a paused-then-closed pool cannot trap beneficiary funds —
    ///         unpausePool() carries notClosed, so without this beneficiaries could be locked out forever.
    function closePool() external onlyOwner {
        if (closed) revert PoolAlreadyClosed();
        closed = true;
        paused = false;
        _freezeAllTranches();
        emit PoolClosedEvent();
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function claimableAmount(
        address beneficiary,
        address token
    ) external view returns (uint256) {
        return _claimable(beneficiary, token);
    }

    /// @notice Next unlock timestamp for an active allocation, 0 if inactive/removed.
    function nextUnlockTime(
        address beneficiary,
        address token
    ) external view returns (uint256) {
        Tranche[] storage tranches = _tranches[beneficiary][token];
        if (tranches.length == 0) return 0;
        Tranche storage t = tranches[tranches.length - 1];
        if (t.endTime != 0) return 0;
        if (block.timestamp < t.startTime) return t.startTime;
        uint256 periodsElapsed = (block.timestamp - t.startTime) /
            t.periodSeconds;
        return t.startTime + (periodsElapsed + 1) * t.periodSeconds;
    }

    /// @notice Full allocation snapshot for a beneficiary across all tokens.
    function getAllocations(
        address beneficiary
    ) external view returns (AllocationView[] memory) {
        address[] storage tokens = _beneficiaryTokens[beneficiary];
        AllocationView[] memory result = new AllocationView[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            Tranche[] storage tranches = _tranches[beneficiary][token];
            // Invariant: a token enters _beneficiaryTokens only via setAllocation,
            // which atomically pushes a tranche — so tranches.length >= 1 here.
            Tranche storage last = tranches[tranches.length - 1];
            bool active = last.endTime == 0;

            uint256 next = 0;
            if (active) {
                if (block.timestamp < last.startTime) {
                    next = last.startTime;
                } else {
                    uint256 p = (block.timestamp - last.startTime) /
                        last.periodSeconds;
                    next = last.startTime + (p + 1) * last.periodSeconds;
                }
            }

            result[i] = AllocationView({
                token: token,
                frequency: _secondsToFrequency(last.periodSeconds),
                amountPerPeriod: last.amountPerPeriod,
                nextClaimTime: next,
                pendingAmount: _claimable(beneficiary, token),
                active: active
            });
        }
        return result;
    }

    function getBeneficiaries() external view returns (address[] memory) {
        return _beneficiaries;
    }

    function totalCommitted(address token) external view returns (uint256) {
        return _totalCommitted(token);
    }

    // -------------------------------------------------------------------------
    // Internal: accrual math
    // -------------------------------------------------------------------------

    /// @dev Core accrual logic. For each tranche we compute how many complete
    ///      periods elapsed within [startTime, effectiveEnd], then multiply by rate.
    ///
    ///      effectiveEnd = endTime if sealed, else block.timestamp.
    ///      If effectiveEnd <= startTime no full period has elapsed → 0 for that tranche.
    ///
    ///      Invariant: tranches are non-overlapping and ordered by creation time.
    ///      Sealed tranche[i].endTime == tranche[i+1] creation time (block.timestamp
    ///      at the moment of the edit), so there is no gap or overlap in accounting.
    function _claimable(
        address beneficiary,
        address token
    ) internal view returns (uint256) {
        Tranche[] storage tranches = _tranches[beneficiary][token];
        if (tranches.length == 0) return 0;

        uint256 totalAccrued = 0;

        for (uint256 i = 0; i < tranches.length; i++) {
            Tranche storage t = tranches[i];
            // effectiveEnd: use block.timestamp for the active (last) tranche.
            uint256 effectiveEnd = t.endTime == 0 ? block.timestamp : t.endTime;

            // No full period can elapse if effectiveEnd hasn't passed startTime.
            if (effectiveEnd <= t.startTime) continue;

            uint256 periods = (effectiveEnd - t.startTime) / t.periodSeconds;
            totalAccrued += periods * t.amountPerPeriod;
        }

        uint256 alreadyClaimed = _claimed[beneficiary][token];
        // Underflow guard: totalAccrued should always >= alreadyClaimed, but be safe.
        return
            totalAccrued > alreadyClaimed ? totalAccrued - alreadyClaimed : 0;
    }

    function _totalCommitted(address token) internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            total += _claimable(_beneficiaries[i], token);
        }
        return total;
    }

    /// @dev Seals all active tranches at block.timestamp. Called once on closePool().
    function _freezeAllTranches() internal {
        uint256 now_ = block.timestamp;
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            address b = _beneficiaries[i];
            address[] storage tokens = _beneficiaryTokens[b];
            for (uint256 j = 0; j < tokens.length; j++) {
                Tranche[] storage tranches = _tranches[b][tokens[j]];
                if (
                    tranches.length > 0 &&
                    tranches[tranches.length - 1].endTime == 0
                ) {
                    tranches[tranches.length - 1].endTime = now_;
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Internal: fee + transfer
    // -------------------------------------------------------------------------

    function _calcFee(uint256 amount) internal view returns (uint256) {
        uint256 bps = IPayrollFactory(factory).feeBps();
        return (amount * bps) / 10_000;
    }

    function _sendFee(address token, uint256 fee) internal {
        if (fee == 0) return;
        if (token == address(0)) {
            IPayrollFactory(factory).recordFee{value: fee}(address(0), fee);
        } else {
            IERC20(token).safeTransfer(factory, fee);
            IPayrollFactory(factory).recordFee(token, fee);
        }
    }

    function _transfer(
        address token,
        address payable to,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // -------------------------------------------------------------------------
    // Internal: helpers
    // -------------------------------------------------------------------------

    function _periodSeconds(Frequency f) internal pure returns (uint256) {
        if (f == Frequency.WEEKLY) return 7 days;
        if (f == Frequency.MONTHLY) return 30 days;
        return 90 days;
    }

    function _secondsToFrequency(uint256 s) internal pure returns (Frequency) {
        if (s == 7 days) return Frequency.WEEKLY;
        if (s == 30 days) return Frequency.MONTHLY;
        return Frequency.QUARTERLY;
    }

    // -------------------------------------------------------------------------
    // Ownership
    // -------------------------------------------------------------------------

    /// @notice Disabled — renouncing would strand uncommitted funds and admin controls.
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }
}
