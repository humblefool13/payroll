// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IPayrollFactory} from "./interfaces/IPayrollFactory.sol";

/// @notice A single payroll pool. Deployed by PayrollFactory; owned by the pool admin.
///
/// Allocation model — O(1) accounting
/// ──────────────────────────────────
/// Each (beneficiary, token) pair carries at most ONE active tranche plus a
/// `settled` accumulator of everything earned by previous (superseded/removed)
/// tranches. When the admin edits an allocation, the active tranche's final
/// accrual is folded into `settled` and the slot is overwritten with the new
/// tranche. Claim cost therefore does NOT grow with the number of edits.
///
/// Accrual of the active tranche:
///
///   end = paused ? pausedAt : block.timestamp      (pause freezes accrual)
///   accrued = end >= startTime
///       ? (floor((end - startTime) / periodSeconds) + 1) * amountPerPeriod
///       : 0
///
///   The +1 makes the first period claimable at startTime itself.
///
/// Folding (edit / remove / close) uses the strict rule (end <= startTime → 0)
/// so a tranche sealed in the same block it starts contributes nothing
/// (phantom-period guard).
///
/// Total claimable = settled + activeAccrual - alreadyClaimed
///
/// Pause semantics
/// ───────────────
///   - Claims remain ALLOWED while paused (pause can never trap earned funds).
///   - Accrual freezes at `pausedAt`; no new periods unlock during a pause.
///   - setAllocation is disabled while paused; removeAllocation stays available
///     (it folds only the accrual earned up to `pausedAt`).
///   - On unpause every active tranche's schedule shifts forward by the pause
///     duration, so accrual resumes exactly where it stopped — periods that
///     would have unlocked during the pause are delayed, not granted
///     retroactively. A start scheduled inside the pause window fires at the
///     moment of unpause.
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
    error TooManyBeneficiaries();
    error NothingToRescue();
    error UseRescueETH();
    error NotABeneficiary();
    error HasActiveAllocation();
    error HasUnclaimedBalance();

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    enum Frequency {
        WEEKLY, // 7 days
        MONTHLY, // 30 days
        QUARTERLY // 90 days
    }

    struct Tranche {
        uint256 amountPerPeriod; // in token's smallest unit; 0 = never allocated
        uint256 startTime; // unix timestamp of the first claimable period start
        uint256 periodSeconds; // seconds per period, derived from Frequency at creation
        uint256 endTime; // 0 = active; set when superseded/removed (accrual already folded into _settled)
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

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Hard cap on beneficiaries per pool; keeps the loops in
    ///         _totalCommitted, _settleAll and unpausePool within block gas limits.
    uint256 public constant MAX_BENEFICIARIES = 50;

    /// @dev Guards one-time factory registration per beneficiary per pool.
    mapping(address => bool) private _everRegistered;

    /// @dev The current (or last) tranche per (beneficiary, token).
    ///      amountPerPeriod == 0 → never allocated. endTime != 0 → inactive,
    ///      and its accrual has already been folded into _settled.
    mapping(address beneficiary => mapping(address token => Tranche))
        private _alloc;

    /// @dev Accrual folded out of superseded/removed tranches per (beneficiary, token).
    mapping(address beneficiary => mapping(address token => uint256 amount))
        private _settled;

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

    /// @notice Timestamp at which the current pause began; 0 when not paused.
    uint256 public pausedAt;

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
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event BeneficiaryEvicted(address indexed beneficiary);

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

    function depositETH() external payable onlyOwner nonReentrant {
        if (!IPayrollFactory(factory).tokenWhitelisted(address(0)))
            revert TokenNotWhitelisted();
        poolBalance[address(0)] += msg.value;
        emit Deposited(address(0), msg.sender, msg.value);
    }

    /// @notice Deposit an ERC-20 token. Caller must have approved this contract for `amount`.
    function depositToken(
        address token,
        uint256 amount
    ) external onlyOwner nonReentrant {
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
    ///         Edit behaviour: the currently active tranche (if any) is folded —
    ///         every period that already unlocked stays owed — and the slot is
    ///         overwritten with the new rate starting at `startTime`.
    ///
    ///         NOTE: the new tranche's first period unlocks AT `startTime`. An
    ///         edit with startTime == now therefore grants one full new-rate
    ///         period immediately, on top of what the old tranche already
    ///         unlocked. To change the rate without an extra immediate payout,
    ///         set `startTime` to the old allocation's next unlock time.
    ///
    ///         Disabled while paused: unpause first (unpause shifts schedules,
    ///         and edits made mid-pause would not shift correctly).
    ///
    /// @param startTime First period-start timestamp. Must be >= block.timestamp.
    function setAllocation(
        address beneficiary,
        address token,
        uint256 amountPerPeriod,
        Frequency frequency,
        uint256 startTime
    ) external onlyOwner notClosed notPaused {
        if (beneficiary == address(0)) revert ZeroBeneficiary();
        if (beneficiary == address(this) || beneficiary == factory)
            revert InvalidBeneficiary();
        if (!IPayrollFactory(factory).tokenWhitelisted(token))
            revert TokenNotWhitelisted();
        if (amountPerPeriod == 0) revert ZeroAmount();
        if (startTime < block.timestamp) revert StartTimeInPast();

        Tranche storage t = _alloc[beneficiary][token];

        // Fold the active tranche's final accrual into the settled accumulator.
        if (t.amountPerPeriod != 0 && t.endTime == 0) {
            _seal(beneficiary, token);
        }

        _alloc[beneficiary][token] = Tranche({
            amountPerPeriod: amountPerPeriod,
            startTime: startTime,
            periodSeconds: _periodSeconds(frequency),
            endTime: 0
        });

        // One-time registration per beneficiary per pool in the factory registry.
        if (!_everRegistered[beneficiary]) {
            _everRegistered[beneficiary] = true;
            IPayrollFactory(factory).registerBeneficiary(
                beneficiary,
                address(this)
            );
        }
        if (!_isBeneficiary[beneficiary]) {
            if (_beneficiaries.length >= MAX_BENEFICIARIES)
                revert TooManyBeneficiaries();
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
    ///         Available while paused; folds only accrual earned up to pausedAt.
    function removeAllocation(
        address beneficiary,
        address token
    ) external onlyOwner {
        Tranche storage t = _alloc[beneficiary][token];
        if (t.amountPerPeriod == 0) revert NoAllocation();
        if (t.endTime != 0) revert AllocationAlreadyRemoved();
        _seal(beneficiary, token);
        emit AllocationRemoved(beneficiary, token);
    }

    /// @notice Remove a fully-settled beneficiary from the active list, freeing one slot under MAX_BENEFICIARIES.
    ///         All allocations must be removed and all claimable balances claimed first.
    ///         Clears all beneficiary state for a complete clean slate; re-hiring re-registers from scratch.
    function evictBeneficiary(
        address beneficiary
    ) external onlyOwner nonReentrant {
        if (!_isBeneficiary[beneficiary]) revert NotABeneficiary();

        // --- Validate: no active allocations and no unclaimed balance ---
        address[] storage tokens = _beneficiaryTokens[beneficiary];
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            Tranche storage t = _alloc[beneficiary][token];
            if (t.amountPerPeriod != 0 && t.endTime == 0)
                revert HasActiveAllocation();
            if (_claimable(beneficiary, token) > 0)
                revert HasUnclaimedBalance();
        }

        // --- Clear per-token state ---
        // Must iterate tokens before deleting _beneficiaryTokens (array still needed for loop).
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            delete _alloc[beneficiary][token];
            delete _settled[beneficiary][token];
            delete _claimed[beneficiary][token];
            delete _hasToken[beneficiary][token];
        }
        delete _beneficiaryTokens[beneficiary];

        // --- Remove from _beneficiaries (swap-and-pop) ---
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            if (_beneficiaries[i] == beneficiary) {
                _beneficiaries[i] = _beneficiaries[_beneficiaries.length - 1];
                _beneficiaries.pop();
                break;
            }
        }

        // --- Reset registration flags ---
        IPayrollFactory(factory).unregisterBeneficiary(
            beneficiary,
            address(this)
        );
        _everRegistered[beneficiary] = false;
        _isBeneficiary[beneficiary] = false;
        emit BeneficiaryEvicted(beneficiary);
    }

    // -------------------------------------------------------------------------
    // Beneficiary: claim
    // -------------------------------------------------------------------------

    /// @notice Claim everything accrued for `token`. Allowed while paused and
    ///         after close — earned funds can never be trapped by pool state.
    function claim(address token) external nonReentrant {
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

    /// @notice Pause accrual. Beneficiaries can still claim what was already
    ///         earned; no new periods unlock until unpausePool().
    function pausePool() external onlyOwner notClosed {
        if (paused) revert PoolAlreadyPaused();
        paused = true;
        pausedAt = block.timestamp;
        emit PoolPausedEvent();
    }

    /// @notice Resume accrual. Every active schedule shifts forward by the
    ///         pause duration so it continues exactly where it stopped; starts
    ///         scheduled inside the pause window fire now.
    function unpausePool() external onlyOwner notClosed {
        if (!paused) revert PoolNotPaused();
        paused = false;
        uint256 delta = block.timestamp - pausedAt;
        if (delta > 0) {
            for (uint256 i = 0; i < _beneficiaries.length; i++) {
                address b = _beneficiaries[i];
                address[] storage tokens = _beneficiaryTokens[b];
                for (uint256 j = 0; j < tokens.length; j++) {
                    Tranche storage t = _alloc[b][tokens[j]];
                    if (t.amountPerPeriod == 0 || t.endTime != 0) continue;
                    if (t.startTime <= pausedAt) {
                        t.startTime += delta;
                    } else if (t.startTime < block.timestamp) {
                        t.startTime = block.timestamp;
                    }
                }
            }
        }
        pausedAt = 0;
        emit PoolUnpausedEvent();
    }

    /// @notice Permanently close the pool.
    ///         Folds all active tranches (pause-aware: a paused pool settles at
    ///         pausedAt). Admin may still withdraw uncommitted funds and deposit
    ///         to cover shortfalls. Beneficiaries may still claim everything
    ///         accrued up to close time.
    function closePool() external onlyOwner {
        if (closed) revert PoolAlreadyClosed();
        _settleAll(); // before clearing `paused` so folding respects pausedAt
        closed = true;
        paused = false;
        pausedAt = 0;
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
    ///         While paused, returns the projected unlock assuming an immediate
    ///         unpause (the real unlock recedes 1:1 while the pause continues).
    function nextUnlockTime(
        address beneficiary,
        address token
    ) external view returns (uint256) {
        Tranche storage t = _alloc[beneficiary][token];
        if (t.amountPerPeriod == 0 || t.endTime != 0) return 0;
        uint256 start = _projectedStart(t);
        if (block.timestamp < start) return start;
        uint256 periodsElapsed = (block.timestamp - start) / t.periodSeconds;
        return start + (periodsElapsed + 1) * t.periodSeconds;
    }

    /// @notice Full allocation snapshot for a beneficiary across all tokens.
    function getAllocations(
        address beneficiary
    ) external view returns (AllocationView[] memory) {
        address[] storage tokens = _beneficiaryTokens[beneficiary];
        AllocationView[] memory result = new AllocationView[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            Tranche storage t = _alloc[beneficiary][token];
            if (t.amountPerPeriod == 0) {
                // Invariant violation guard: unreachable in normal operation (a token only
                // enters _beneficiaryTokens alongside an allocation write in setAllocation).
                // Emit a safe zero-valued entry rather than panicking.
                result[i] = AllocationView({
                    token: token,
                    frequency: Frequency(0),
                    amountPerPeriod: 0,
                    nextClaimTime: 0,
                    pendingAmount: 0,
                    active: false
                });
                continue;
            }
            bool active = t.endTime == 0;

            uint256 next = 0;
            if (active) {
                uint256 start = _projectedStart(t);
                if (block.timestamp < start) {
                    next = start;
                } else {
                    uint256 p = (block.timestamp - start) / t.periodSeconds;
                    next = start + (p + 1) * t.periodSeconds;
                }
            }

            result[i] = AllocationView({
                token: token,
                frequency: _secondsToFrequency(t.periodSeconds),
                amountPerPeriod: t.amountPerPeriod,
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
    // Admin: rescue stranded funds
    // -------------------------------------------------------------------------

    /// @notice Recover ETH sent to this contract outside of depositETH (e.g. via selfdestruct).
    ///         Only the surplus above poolBalance is rescuable; tracked payroll funds are untouched.
    function rescueETH() external onlyOwner nonReentrant {
        uint256 tracked = poolBalance[address(0)];
        uint256 actual = address(this).balance;
        uint256 excess = actual > tracked ? actual - tracked : 0;
        if (excess == 0) revert NothingToRescue();
        emit Rescued(address(0), msg.sender, excess);
        _transfer(address(0), payable(msg.sender), excess);
    }

    /// @notice Recover ERC-20 tokens sent directly to this contract (bypassing depositToken).
    ///         Only the surplus above poolBalance[token] is rescuable.
    function rescueToken(
        address token,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (token == address(0)) revert UseRescueETH();
        uint256 tracked = poolBalance[token];
        uint256 actual = IERC20(token).balanceOf(address(this));
        uint256 rescuable = actual > tracked ? actual - tracked : 0;
        if (amount == 0 || rescuable == 0) revert NothingToRescue();
        if (amount > rescuable) revert AmountExceedsAvailable();
        emit Rescued(token, msg.sender, amount);
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Internal: accrual math
    // -------------------------------------------------------------------------

    /// @dev End of the accrual window for active tranches: frozen at pausedAt
    ///      while paused, otherwise block.timestamp.
    function _accrualEnd() internal view returns (uint256) {
        return paused ? pausedAt : block.timestamp;
    }

    /// @dev Where the active tranche's schedule stands for VIEW purposes while
    ///      paused: projects the post-unpause startTime as if unpause were now.
    ///      Mirrors the shift rules in unpausePool().
    function _projectedStart(
        Tranche storage t
    ) internal view returns (uint256) {
        uint256 start = t.startTime;
        if (!paused) return start;
        if (start <= pausedAt) return start + (block.timestamp - pausedAt);
        if (start < block.timestamp) return block.timestamp;
        return start;
    }

    /// @dev Total claimable = settled + active-tranche accrual − alreadyClaimed.
    ///      Active rule: the first period unlocks AT startTime (end == start → 1 period).
    function _claimable(
        address beneficiary,
        address token
    ) internal view returns (uint256) {
        uint256 totalAccrued = _settled[beneficiary][token];

        Tranche storage t = _alloc[beneficiary][token];
        if (t.amountPerPeriod != 0 && t.endTime == 0) {
            uint256 end = _accrualEnd();
            if (end >= t.startTime) {
                totalAccrued +=
                    ((end - t.startTime) / t.periodSeconds + 1) *
                    t.amountPerPeriod;
            }
        }

        uint256 alreadyClaimed = _claimed[beneficiary][token];
        // Underflow guard: totalAccrued should always >= alreadyClaimed, but be safe.
        return
            totalAccrued > alreadyClaimed ? totalAccrued - alreadyClaimed : 0;
    }

    /// @dev Fold the active tranche's final accrual into _settled and mark it ended.
    ///      Callers must ensure the tranche is active (amountPerPeriod != 0, endTime == 0).
    ///      Strict rule (end <= start → 0): a tranche sealed at its own startTime
    ///      contributes nothing — phantom-period guard. Pause-aware via _accrualEnd().
    function _seal(address beneficiary, address token) internal {
        Tranche storage t = _alloc[beneficiary][token];
        uint256 end = _accrualEnd();
        if (end > t.startTime) {
            _settled[beneficiary][token] +=
                ((end - t.startTime) / t.periodSeconds + 1) *
                t.amountPerPeriod;
        }
        t.endTime = block.timestamp;
    }

    function _totalCommitted(address token) internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            total += _claimable(_beneficiaries[i], token);
        }
        return total;
    }

    /// @dev Folds every active tranche. Called once on closePool().
    function _settleAll() internal {
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            address b = _beneficiaries[i];
            address[] storage tokens = _beneficiaryTokens[b];
            for (uint256 j = 0; j < tokens.length; j++) {
                Tranche storage t = _alloc[b][tokens[j]];
                if (t.amountPerPeriod != 0 && t.endTime == 0) {
                    _seal(b, tokens[j]);
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

    /// @notice Transfer pool ownership and sync the factory's admin registry.
    ///         Override targets the public function (not _transferOwnership) because
    ///         _transferOwnership is called in the OZ constructor before `factory` is set.
    function transferOwnership(address newOwner) public override onlyOwner {
        address previousOwner = owner();
        super.transferOwnership(newOwner);
        IPayrollFactory(factory).transferPoolAdmin(
            previousOwner,
            newOwner,
            address(this)
        );
    }
}
