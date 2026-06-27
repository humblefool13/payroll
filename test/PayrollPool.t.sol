// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {PayrollFactory} from "../src/PayrollFactory.sol";
import {PayrollPool} from "../src/PayrollPool.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract PayrollPoolTest is Test {
    PayrollFactory factory;
    PayrollPool pool;
    MockERC20 usdt;
    MockERC20 usdc;

    address platformOwner = makeAddr("platformOwner");
    address admin        = makeAddr("admin");
    address alice        = makeAddr("alice");
    address bob          = makeAddr("bob");

    uint256 constant MONTH   = 30 days;
    uint256 constant WEEK    = 7 days;
    uint256 constant QUARTER = 90 days;

    function setUp() public {
        vm.prank(platformOwner);
        factory = new PayrollFactory(platformOwner);

        usdt = new MockERC20("USDT", "USDT");
        usdc = new MockERC20("USDC", "USDC");

        vm.startPrank(platformOwner);
        factory.whitelistToken(address(usdt));
        factory.whitelistToken(address(usdc));
        vm.stopPrank();

        vm.prank(admin);
        pool = PayrollPool(factory.deployPool());

        usdt.mint(admin, 1_000_000e18);
        usdc.mint(admin, 1_000_000e18);
        vm.deal(admin, 1000 ether);

        vm.startPrank(admin);
        usdt.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // =========================================================================
    // Deposits
    // =========================================================================

    function test_depositToken() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);
        assertEq(pool.poolBalance(address(usdt)), 100_000e18);
    }

    function test_depositETH() public {
        vm.prank(admin);
        pool.depositETH{value: 10 ether}();
        assertEq(pool.poolBalance(address(0)), 10 ether);
    }

    function test_deposit_revertsNonOwner() public {
        usdt.mint(alice, 1000e18);
        vm.startPrank(alice);
        usdt.approve(address(pool), 1000e18);
        vm.expectRevert();
        pool.depositToken(address(usdt), 1000e18);
        vm.stopPrank();
    }

    function test_deposit_revertsUnwhitelistedToken() public {
        MockERC20 rogue = new MockERC20("RGT", "RGT");
        rogue.mint(admin, 1000e18);
        vm.startPrank(admin);
        rogue.approve(address(pool), 1000e18);
        vm.expectRevert(PayrollPool.TokenNotWhitelisted.selector);
        pool.depositToken(address(rogue), 1000e18);
        vm.stopPrank();
    }

    function test_deposit_allowedOnClosed() public {
        vm.prank(admin);
        pool.closePool();
        // Deposits remain open after close so underfunded pools can be rescued.
        vm.prank(admin);
        pool.depositToken(address(usdt), 1000e18);
        assertEq(pool.poolBalance(address(usdt)), 1000e18);
    }

    function test_depositToken_useDepositETHForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(PayrollPool.UseDepositETH.selector);
        pool.depositToken(address(0), 1 ether);
    }

    // =========================================================================
    // Admin withdrawal
    // =========================================================================

    function test_adminWithdraw_noAllocations() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 balBefore = usdt.balanceOf(admin);
        vm.prank(admin);
        pool.adminWithdraw(address(usdt), 50_000e18);

        assertEq(usdt.balanceOf(admin) - balBefore, 50_000e18);
        assertEq(pool.poolBalance(address(usdt)), 50_000e18);
    }

    function test_adminWithdraw_withFee() public {
        vm.prank(platformOwner);
        factory.setFeeBps(100); // 1%

        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 balBefore = usdt.balanceOf(admin);
        vm.prank(admin);
        pool.adminWithdraw(address(usdt), 10_000e18);

        assertEq(usdt.balanceOf(admin) - balBefore, 9_900e18);
        assertEq(factory.accruedFees(address(usdt)), 100e18);
    }

    function test_adminWithdraw_cannotExceedAvailable() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 10_000e18);

        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 3_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);

        vm.warp(block.timestamp + MONTH); // 6000 committed (2 periods), 4000 available

        vm.prank(admin);
        vm.expectRevert(PayrollPool.AmountExceedsAvailable.selector);
        pool.adminWithdraw(address(usdt), 5_000e18);

        vm.prank(admin);
        pool.adminWithdraw(address(usdt), 4_000e18);
    }

    function test_adminWithdraw_revertsNonOwner() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 1000e18);
        vm.prank(alice);
        vm.expectRevert();
        pool.adminWithdraw(address(usdt), 100e18);
    }

    function test_adminWithdraw_ETH() public {
        vm.prank(platformOwner);
        factory.setFeeBps(50); // 0.5%

        vm.prank(admin);
        pool.depositETH{value: 10 ether}();

        uint256 balBefore = admin.balance;
        vm.prank(admin);
        pool.adminWithdraw(address(0), 2 ether);

        uint256 fee = (2 ether * 50) / 10_000;
        assertEq(admin.balance - balBefore, 2 ether - fee);
        assertEq(factory.accruedFees(address(0)), fee);
    }

    // =========================================================================
    // Allocations
    // =========================================================================

    function test_setAllocation_basic() public {
        uint256 start = block.timestamp + 1 days;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        PayrollPool.AllocationView[] memory allocs = pool.getAllocations(alice);
        assertEq(allocs.length, 1);
        assertEq(allocs[0].token, address(usdt));
        assertEq(allocs[0].amountPerPeriod, 2_000e18);
        assertTrue(allocs[0].active);
    }

    function test_setAllocation_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        pool.setAllocation(bob, address(usdt), 100e18, PayrollPool.Frequency.MONTHLY, block.timestamp);
    }

    function test_setAllocation_revertsStartInPast() public {
        vm.prank(admin);
        vm.expectRevert(PayrollPool.StartTimeInPast.selector);
        pool.setAllocation(alice, address(usdt), 100e18, PayrollPool.Frequency.MONTHLY, block.timestamp - 1);
    }

    function test_setAllocation_revertsZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(PayrollPool.ZeroAmount.selector);
        pool.setAllocation(alice, address(usdt), 0, PayrollPool.Frequency.MONTHLY, block.timestamp);
    }

    function test_setAllocation_revertsZeroBeneficiary() public {
        vm.prank(admin);
        vm.expectRevert(PayrollPool.ZeroBeneficiary.selector);
        pool.setAllocation(address(0), address(usdt), 100e18, PayrollPool.Frequency.MONTHLY, block.timestamp);
    }

    function test_setAllocation_revertsUnwhitelistedToken() public {
        MockERC20 rogue = new MockERC20("RGT", "RGT");
        vm.prank(admin);
        vm.expectRevert(PayrollPool.TokenNotWhitelisted.selector);
        pool.setAllocation(alice, address(rogue), 100e18, PayrollPool.Frequency.MONTHLY, block.timestamp);
    }

    function test_setAllocation_multiToken() public {
        uint256 start = block.timestamp;
        vm.startPrank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY,  start);
        pool.setAllocation(alice, address(usdc), 500e18,   PayrollPool.Frequency.WEEKLY,   start);
        pool.setAllocation(alice, address(0),    1 ether,  PayrollPool.Frequency.QUARTERLY, start);
        vm.stopPrank();

        assertEq(pool.getAllocations(alice).length, 3);
    }

    function test_setAllocation_adminAsOwnBeneficiary() public {
        vm.prank(admin);
        pool.setAllocation(admin, address(usdt), 500e18, PayrollPool.Frequency.WEEKLY, block.timestamp);
        assertEq(pool.getAllocations(admin).length, 1);
    }

    // =========================================================================
    // Edit allocation — tranche math correctness
    // =========================================================================

    function test_editAllocation_preservesOldAccrual() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        // After 2 months: 3 payments (at start, start+MONTH, start+2*MONTH) → 6000 accrued in tranche 0
        vm.warp(start + 2 * MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), 6_000e18);

        // Admin raises rate to 3000/month starting now
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 3_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);

        // Tranche 0 sealed at 2*MONTH → 6000 still owed; tranche 1 immediately yields 1 period → 9000
        assertEq(pool.claimableAmount(alice, address(usdt)), 9_000e18);

        // 1 month into tranche 1 → 6000 + 6000 = 12000
        vm.warp(block.timestamp + MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), 12_000e18);

        // 2nd month in tranche 1 → 6000 + 9000 = 15000
        vm.warp(block.timestamp + MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), 15_000e18);
    }

    function test_editAllocation_newStartInFuture_gapIsNotAccrued() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH); // 2 payments (at start, start+MONTH) → 4000 accrued in tranche 0

        // New tranche starts 30 days from now (gap between old endTime and new startTime)
        uint256 newStart = block.timestamp + MONTH;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 3_000e18, PayrollPool.Frequency.MONTHLY, newStart);

        // During the gap — still only 4000 from tranche 0
        vm.warp(newStart - 1);
        assertEq(pool.claimableAmount(alice, address(usdt)), 4_000e18);

        // 1 period after new tranche start → 4000 + 6000 = 10000
        vm.warp(newStart + MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), 10_000e18);
    }

    function test_editAllocation_partialPeriodNotCounted() public {
        // Tranche sealed mid-period: floor division must discard the partial period.
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, start);

        // Seal halfway through month 2 → floor(1.5) + 1 = 2 periods counted in tranche 0
        vm.warp(start + MONTH + MONTH / 2);
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 500e18, PayrollPool.Frequency.MONTHLY, block.timestamp);

        // Tranche 0: 2 periods (partial month discarded by floor) → 2000
        // Tranche 1: 1 period immediately at its startTime → 500
        assertEq(pool.claimableAmount(alice, address(usdt)), 2_500e18);
    }

    function test_claimedAmountNotDoubleCountedAfterEdit() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + 2 * MONTH); // 3 periods accrued → 3000

        vm.prank(alice);
        pool.claim(address(usdt)); // claims 3000; _claimed = 3000

        // Admin changes rate; tranche 1 immediately yields 1 period → 500 claimable
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 500e18, PayrollPool.Frequency.MONTHLY, block.timestamp);

        assertEq(pool.claimableAmount(alice, address(usdt)), 500e18);

        // 1 more period in new tranche → 1000 claimable
        vm.warp(block.timestamp + MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), 1_000e18);
    }

    // =========================================================================
    // Remove allocation
    // =========================================================================

    function test_removeAllocation_stopsFutureAccrual() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH);
        vm.prank(admin);
        pool.removeAllocation(alice, address(usdt));

        assertEq(pool.claimableAmount(alice, address(usdt)), 4_000e18);

        vm.warp(block.timestamp + 10 * MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), 4_000e18);
    }

    function test_removeAllocation_remainsClaimable() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + 3 * MONTH);
        vm.prank(admin);
        pool.removeAllocation(alice, address(usdt));

        vm.prank(alice);
        pool.claim(address(usdt));
        assertEq(usdt.balanceOf(alice), 8_000e18); // no fee set
    }

    function test_removeAllocation_revertsIfNotActive() public {
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);
        vm.prank(admin);
        pool.removeAllocation(alice, address(usdt));

        vm.prank(admin);
        vm.expectRevert(PayrollPool.AllocationAlreadyRemoved.selector);
        pool.removeAllocation(alice, address(usdt));
    }

    function test_removeAllocation_revertsNoAllocation() public {
        vm.prank(admin);
        vm.expectRevert(PayrollPool.NoAllocation.selector);
        pool.removeAllocation(alice, address(usdt));
    }

    function test_removeAllocation_revertsNonOwner() public {
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);

        vm.prank(alice);
        vm.expectRevert();
        pool.removeAllocation(alice, address(usdt));
    }

    // =========================================================================
    // Claiming
    // =========================================================================

    function test_claim_basic() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH);
        vm.prank(alice);
        pool.claim(address(usdt));

        assertEq(usdt.balanceOf(alice), 4_000e18);
        assertEq(pool.claimableAmount(alice, address(usdt)), 0);
    }

    function test_claim_accumulatesOverMultiplePeriods() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.WEEKLY, start);

        vm.warp(start + 4 * WEEK);
        assertEq(pool.claimableAmount(alice, address(usdt)), 5_000e18);

        vm.prank(alice);
        pool.claim(address(usdt));
        assertEq(usdt.balanceOf(alice), 5_000e18);

        vm.warp(block.timestamp + 2 * WEEK);
        assertEq(pool.claimableAmount(alice, address(usdt)), 2_000e18);
    }

    function test_claim_withFee() public {
        vm.prank(platformOwner);
        factory.setFeeBps(100); // 1%

        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 10_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH);
        vm.prank(alice);
        pool.claim(address(usdt));

        assertEq(usdt.balanceOf(alice), 19_800e18);
        assertEq(factory.accruedFees(address(usdt)), 200e18);
    }

    function test_claim_ETH() public {
        vm.prank(admin);
        pool.depositETH{value: 10 ether}();

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(0), 1 ether, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        pool.claim(address(0));
        assertEq(alice.balance - balBefore, 2 ether);
    }

    function test_claim_revertsNothingToClaim() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp + 1 days);

        vm.prank(alice);
        vm.expectRevert(PayrollPool.NothingToClaim.selector);
        pool.claim(address(usdt));
    }

    function test_claim_allowedWhilePaused() public {
        // Pause freezes accrual but must never trap already-earned funds.
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH);
        vm.prank(admin);
        pool.pausePool();

        vm.prank(alice);
        pool.claim(address(usdt));
        assertEq(usdt.balanceOf(alice), 4_000e18);
    }

    function test_claim_allowedAfterUnpause() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH);
        vm.prank(admin);
        pool.pausePool();
        vm.prank(admin);
        pool.unpausePool();

        vm.prank(alice);
        pool.claim(address(usdt));
        assertEq(usdt.balanceOf(alice), 4_000e18);
    }

    function test_claim_revertsPoolUnderfunded() public {
        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH);
        vm.prank(alice);
        vm.expectRevert(PayrollPool.PoolUnderfunded.selector);
        pool.claim(address(usdt));
    }

    // =========================================================================
    // Multiple beneficiaries
    // =========================================================================

    function test_multipleBeneficiaries_independentClaims() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.startPrank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);
        pool.setAllocation(bob,   address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, start);
        vm.stopPrank();

        vm.warp(start + MONTH);
        vm.prank(alice);
        pool.claim(address(usdt));
        vm.prank(bob);
        pool.claim(address(usdt));

        assertEq(usdt.balanceOf(alice), 4_000e18);
        assertEq(usdt.balanceOf(bob),   2_000e18);
    }

    function test_committedAmountBlocksAdminWithdraw() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 5_000e18);

        uint256 start = block.timestamp;
        vm.startPrank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);
        pool.setAllocation(bob,   address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);
        vm.stopPrank();

        vm.warp(start + MONTH); // 8000 committed total (4000 each), pool only has 5000

        vm.prank(admin);
        vm.expectRevert(PayrollPool.AmountExceedsAvailable.selector);
        pool.adminWithdraw(address(usdt), 1e18); // nothing available — all 5000 is committed
    }

    // =========================================================================
    // Frequencies
    // =========================================================================

    function test_weeklyFrequency() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 500e18, PayrollPool.Frequency.WEEKLY, start);

        vm.warp(start + 3 * WEEK);
        assertEq(pool.claimableAmount(alice, address(usdt)), 2_000e18);
    }

    function test_quarterlyFrequency() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 12_000e18, PayrollPool.Frequency.QUARTERLY, start);

        vm.warp(start + 2 * QUARTER);
        assertEq(pool.claimableAmount(alice, address(usdt)), 36_000e18);
    }

    function test_futureStartTime_nothingBeforeStart() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp + 7 days;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start - 1);
        assertEq(pool.claimableAmount(alice, address(usdt)), 0);

        vm.warp(start); // first claim available at startTime
        assertEq(pool.claimableAmount(alice, address(usdt)), 2_000e18);

        vm.warp(start + MONTH); // second claim
        assertEq(pool.claimableAmount(alice, address(usdt)), 4_000e18);
    }

    // =========================================================================
    // nextUnlockTime
    // =========================================================================

    function test_nextUnlockTime_beforeStart() public {
        uint256 start = block.timestamp + 7 days;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, start);
        assertEq(pool.nextUnlockTime(alice, address(usdt)), start);
    }

    function test_nextUnlockTime_afterStart() public {
        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH / 2);
        assertEq(pool.nextUnlockTime(alice, address(usdt)), start + MONTH);
    }

    function test_nextUnlockTime_removedAllocation() public {
        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, start);
        vm.prank(admin);
        pool.removeAllocation(alice, address(usdt));
        assertEq(pool.nextUnlockTime(alice, address(usdt)), 0);
    }

    function test_nextUnlockTime_noAllocation() public view {
        assertEq(pool.nextUnlockTime(alice, address(usdt)), 0);
    }

    // =========================================================================
    // Pool lifecycle
    // =========================================================================

    function test_pauseUnpause() public {
        vm.prank(admin);
        pool.pausePool();
        assertTrue(pool.paused());
        vm.prank(admin);
        pool.unpausePool();
        assertFalse(pool.paused());
    }

    function test_pause_revertsIfAlreadyPaused() public {
        vm.prank(admin);
        pool.pausePool();
        vm.prank(admin);
        vm.expectRevert(PayrollPool.PoolAlreadyPaused.selector);
        pool.pausePool();
    }

    function test_unpause_revertsIfNotPaused() public {
        vm.prank(admin);
        vm.expectRevert(PayrollPool.PoolNotPaused.selector);
        pool.unpausePool();
    }

    function test_closePool_freezesAccrual() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH);
        vm.prank(admin);
        pool.closePool();
        assertTrue(pool.closed());

        uint256 frozenAmount = pool.claimableAmount(alice, address(usdt));

        vm.warp(block.timestamp + 10 * MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), frozenAmount);
    }

    function test_closePool_beneficiaryCanStillClaim() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + 2 * MONTH);
        vm.prank(admin);
        pool.closePool();

        vm.prank(alice);
        pool.claim(address(usdt));
        assertEq(usdt.balanceOf(alice), 6_000e18);
    }

    function test_closePool_adminCanWithdrawExcess() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 10_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH); // 4000 committed to alice (periods 0 and 1)
        vm.prank(admin);
        pool.closePool();

        uint256 balBefore = usdt.balanceOf(admin);
        vm.prank(admin);
        pool.adminWithdraw(address(usdt), 6_000e18);
        assertEq(usdt.balanceOf(admin) - balBefore, 6_000e18);
    }

    function test_closePool_revertsIfAlreadyClosed() public {
        vm.prank(admin);
        pool.closePool();
        vm.prank(admin);
        vm.expectRevert(PayrollPool.PoolAlreadyClosed.selector);
        pool.closePool();
    }

    function test_closePool_allowsDepositToRescueUnderfundedBeneficiary() public {
        // Scenario: pool closes underfunded — Carol cannot claim because Alice and Bob
        // claimed first. Admin tops up after close so Carol can claim. No funds locked.
        address carol = makeAddr("carol");

        vm.prank(admin);
        pool.depositToken(address(usdt), 8_000e18); // only covers 2 of 3 × 4k claimable

        uint256 start = block.timestamp;
        vm.startPrank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);
        pool.setAllocation(bob,   address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);
        pool.setAllocation(carol, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);
        vm.stopPrank();

        vm.warp(start + MONTH); // 2 periods each → 4k claimable each; 12k committed, 8k in pool

        vm.prank(admin);
        pool.closePool();

        vm.prank(alice);
        pool.claim(address(usdt)); // pool: 8k → 4k ✓
        vm.prank(bob);
        pool.claim(address(usdt)); // pool: 4k → 0 ✓

        // Carol is locked out — first-come-first-served exhausted the pool
        vm.prank(carol);
        vm.expectRevert(PayrollPool.PoolUnderfunded.selector);
        pool.claim(address(usdt));

        // Admin tops up AFTER close — deposits are now allowed on closed pools
        vm.prank(admin);
        pool.depositToken(address(usdt), 4_000e18);

        // Carol can now claim — no funds permanently locked
        vm.prank(carol);
        pool.claim(address(usdt));
        assertEq(usdt.balanceOf(carol), 4_000e18);
    }

    function test_closePool_revertsNewAllocation() public {
        vm.prank(admin);
        pool.closePool();
        vm.prank(admin);
        vm.expectRevert(PayrollPool.PoolClosedError.selector);
        pool.setAllocation(alice, address(usdt), 100e18, PayrollPool.Frequency.MONTHLY, block.timestamp);
    }

    // =========================================================================
    // Factory registry
    // =========================================================================

    function test_factoryTracksAdminPools() public view {
        address[] memory pools = factory.getAdminPools(admin);
        assertEq(pools.length, 1);
        assertEq(pools[0], address(pool));
    }

    function test_factoryTracksBeneficiaryPools() public {
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);

        address[] memory bPools = factory.getBeneficiaryPools(alice);
        assertEq(bPools.length, 1);
        assertEq(bPools[0], address(pool));
    }

    function test_beneficiaryInMultiplePools() public {
        vm.prank(admin);
        address pool2 = factory.deployPool();

        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);
        vm.prank(admin);
        PayrollPool(pool2).setAllocation(alice, address(usdt), 500e18, PayrollPool.Frequency.WEEKLY, block.timestamp);

        assertEq(factory.getBeneficiaryPools(alice).length, 2);
    }

    function test_getBeneficiaries() public {
        vm.startPrank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);
        pool.setAllocation(bob,   address(usdt), 500e18,   PayrollPool.Frequency.MONTHLY, block.timestamp);
        vm.stopPrank();

        address[] memory beneficiaries = pool.getBeneficiaries();
        assertEq(beneficiaries.length, 2);
    }

    // =========================================================================
    // Hardened input checks (post-audit)
    // =========================================================================

    function test_setAllocation_revertsBeneficiarySelf() public {
        vm.prank(admin);
        vm.expectRevert(PayrollPool.InvalidBeneficiary.selector);
        pool.setAllocation(address(pool), address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);
    }

    function test_setAllocation_revertsBeneficiaryFactory() public {
        vm.prank(admin);
        vm.expectRevert(PayrollPool.InvalidBeneficiary.selector);
        pool.setAllocation(address(factory), address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);
    }

    function test_renounceOwnership_reverts() public {
        vm.prank(admin);
        vm.expectRevert(PayrollPool.RenounceOwnershipDisabled.selector);
        pool.renounceOwnership();
    }

    function test_claim_allowedWhenClosed() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH);
        vm.prank(admin);
        pool.closePool();

        vm.prank(alice);
        pool.claim(address(usdt));
        assertEq(usdt.balanceOf(alice), 4_000e18);
    }

    function test_closePool_autoUnpausesSoClaimsWork() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH);
        vm.prank(admin);
        pool.pausePool();
        assertTrue(pool.paused());

        vm.prank(admin);
        pool.closePool();
        // closePool must clear paused — unpausePool has notClosed, so without this
        // a paused-then-closed pool would permanently trap beneficiary funds.
        assertFalse(pool.paused());

        vm.prank(alice);
        pool.claim(address(usdt));
        assertEq(usdt.balanceOf(alice), 4_000e18);
    }

    // =========================================================================
    // SC-01: Phantom period prevention
    // =========================================================================

    function test_phantomPeriod_preventedWhenSealedAtStart() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 10_000e18);

        // Create allocation with startTime = block.timestamp (allowed by current design)
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);

        // Immediately supersede in the same block — seals Tranche 0 with endTime == startTime.
        // Before the fix this granted 1 phantom period from Tranche 0.
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);

        // Tranche 0 (sealed at own startTime) → 0 periods.
        // Tranche 1 (active, effectiveEnd == startTime) → 1 period (intended first-period design).
        assertEq(pool.claimableAmount(alice, address(usdt)), 2_000e18);
    }

    // =========================================================================
    // SC-05: Beneficiary cap
    // =========================================================================

    function test_maxBeneficiaries_reverts() public {
        uint256 cap = pool.MAX_BENEFICIARIES();
        vm.startPrank(admin);
        for (uint256 i = 1; i <= cap; i++) {
            pool.setAllocation(
                address(uint160(i)),
                address(usdt),
                1e18,
                PayrollPool.Frequency.MONTHLY,
                block.timestamp + 1
            );
        }
        vm.expectRevert(PayrollPool.TooManyBeneficiaries.selector);
        pool.setAllocation(
            address(uint160(cap + 1)),
            address(usdt),
            1e18,
            PayrollPool.Frequency.MONTHLY,
            block.timestamp + 1
        );
        vm.stopPrank();
    }

    // =========================================================================
    // SC-05: evictBeneficiary — slot recycling
    // =========================================================================

    function test_evictBeneficiary_freesSlot() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);

        vm.warp(block.timestamp + MONTH);

        vm.prank(admin);
        pool.removeAllocation(alice, address(usdt));

        vm.prank(alice);
        pool.claim(address(usdt)); // claims all, claimable → 0

        uint256 lenBefore = pool.getBeneficiaries().length;
        vm.prank(admin);
        pool.evictBeneficiary(alice);

        assertEq(pool.getBeneficiaries().length, lenBefore - 1);
    }

    function test_evictBeneficiary_allowsNewBeneficiaryAfterEviction() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        // Fill pool to cap
        uint256 cap = pool.MAX_BENEFICIARIES();
        vm.startPrank(admin);
        for (uint256 i = 1; i <= cap; i++) {
            pool.setAllocation(address(uint160(i)), address(usdt), 1e18, PayrollPool.Frequency.MONTHLY, block.timestamp + 1);
        }
        vm.stopPrank();

        // Evict address(1): remove allocation (starts in future → 0 claimable)
        vm.prank(admin);
        pool.removeAllocation(address(1), address(usdt));
        vm.prank(admin);
        pool.evictBeneficiary(address(1));

        // Now slot is free — one more beneficiary can be added
        vm.prank(admin);
        pool.setAllocation(address(uint160(cap + 1)), address(usdt), 1e18, PayrollPool.Frequency.MONTHLY, block.timestamp + 1);
        assertEq(pool.getBeneficiaries().length, cap);
    }

    function test_evictBeneficiary_revertsIfActive() public {
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);

        vm.prank(admin);
        vm.expectRevert(PayrollPool.HasActiveAllocation.selector);
        pool.evictBeneficiary(alice);
    }

    function test_evictBeneficiary_revertsIfUnclaimed() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);
        vm.warp(block.timestamp + MONTH);
        vm.prank(admin);
        pool.removeAllocation(alice, address(usdt));

        // claimable > 0, not yet claimed
        vm.prank(admin);
        vm.expectRevert(PayrollPool.HasUnclaimedBalance.selector);
        pool.evictBeneficiary(alice);
    }

    function test_evictBeneficiary_revertsIfNotBeneficiary() public {
        vm.prank(admin);
        vm.expectRevert(PayrollPool.NotABeneficiary.selector);
        pool.evictBeneficiary(alice);
    }

    function test_evictBeneficiary_revertsNonOwner() public {
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);
        vm.prank(alice);
        vm.expectRevert();
        pool.evictBeneficiary(alice);
    }

    function test_evictBeneficiary_cleansFactoryRegistry() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);
        assertEq(factory.getBeneficiaryPools(alice).length, 1);

        vm.warp(block.timestamp + MONTH);
        vm.prank(admin);
        pool.removeAllocation(alice, address(usdt));
        vm.prank(alice);
        pool.claim(address(usdt));

        vm.prank(admin);
        pool.evictBeneficiary(alice);

        // Factory registry cleaned up
        assertEq(factory.getBeneficiaryPools(alice).length, 0);
    }

    function test_evictBeneficiary_allowsRehire() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);
        vm.warp(block.timestamp + MONTH);
        vm.prank(admin);
        pool.removeAllocation(alice, address(usdt));
        vm.prank(alice);
        pool.claim(address(usdt));

        vm.prank(admin);
        pool.evictBeneficiary(alice);

        // All state cleared: claimable is 0, allocations is empty.
        assertEq(pool.claimableAmount(alice, address(usdt)), 0);
        assertEq(pool.getAllocations(alice).length, 0);

        // Re-hire: alice gets re-added to pool and factory registry from scratch.
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp + 1);
        assertEq(pool.getBeneficiaries().length, 1);
        assertEq(factory.getBeneficiaryPools(alice).length, 1);
        // Fresh allocation — no phantom accrual from pre-eviction history.
        assertEq(pool.claimableAmount(alice, address(usdt)), 0);
    }

    // =========================================================================
    // SC-09: Rescue functions
    // =========================================================================

    function test_rescueETH_rescuesExcess() public {
        vm.prank(admin);
        pool.depositETH{value: 5 ether}();

        // Simulate ETH force-sent via selfdestruct — vm.deal bypasses receive().
        vm.deal(address(pool), address(pool).balance + 1 ether);

        uint256 balBefore = admin.balance;
        vm.prank(admin);
        pool.rescueETH();

        assertEq(admin.balance - balBefore, 1 ether);
        assertEq(pool.poolBalance(address(0)), 5 ether); // tracked balance unchanged
    }

    function test_rescueETH_revertsNothingToRescue() public {
        vm.prank(admin);
        pool.depositETH{value: 3 ether}();
        // No excess — tracked == actual.
        vm.prank(admin);
        vm.expectRevert(PayrollPool.NothingToRescue.selector);
        pool.rescueETH();
    }

    function test_rescueETH_revertsNonOwner() public {
        vm.deal(address(pool), 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        pool.rescueETH();
    }

    function test_rescueToken_rescuesExcess() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100e18);

        // Direct mint to pool bypasses depositToken — simulates accidental transfer.
        usdt.mint(address(pool), 50e18);

        uint256 balBefore = usdt.balanceOf(admin);
        vm.prank(admin);
        pool.rescueToken(address(usdt), 50e18);

        assertEq(usdt.balanceOf(admin) - balBefore, 50e18);
        assertEq(pool.poolBalance(address(usdt)), 100e18); // tracked balance unchanged
    }

    function test_rescueToken_revertsExceedsRescuable() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100e18);
        usdt.mint(address(pool), 50e18); // 50e18 rescuable

        vm.prank(admin);
        vm.expectRevert(PayrollPool.AmountExceedsAvailable.selector);
        pool.rescueToken(address(usdt), 51e18);
    }

    function test_rescueToken_revertsUseRescueETH() public {
        vm.prank(admin);
        vm.expectRevert(PayrollPool.UseRescueETH.selector);
        pool.rescueToken(address(0), 1 ether);
    }

    function test_rescueToken_revertsNonOwner() public {
        usdt.mint(address(pool), 10e18);
        vm.prank(alice);
        vm.expectRevert();
        pool.rescueToken(address(usdt), 10e18);
    }

    // =========================================================================
    // transferOwnership — factory registry sync
    // =========================================================================

    function test_transferOwnership_updatesFactoryRegistry() public {
        address newAdmin = makeAddr("newAdmin");

        assertEq(factory.getAdminPools(admin).length, 1);
        assertEq(factory.getAdminPools(newAdmin).length, 0);

        vm.prank(admin);
        pool.transferOwnership(newAdmin);

        assertEq(factory.getAdminPools(admin).length, 0);
        assertEq(factory.getAdminPools(newAdmin).length, 1);
        assertEq(factory.getAdminPools(newAdmin)[0], address(pool));
    }

    function test_transferOwnership_newOwnerCanOperate() public {
        address newAdmin = makeAddr("newAdmin");
        usdt.mint(newAdmin, 10_000e18);

        vm.prank(admin);
        pool.transferOwnership(newAdmin);

        assertEq(pool.owner(), newAdmin);

        vm.startPrank(newAdmin);
        usdt.approve(address(pool), type(uint256).max);
        pool.depositToken(address(usdt), 1_000e18);
        pool.setAllocation(alice, address(usdt), 100e18, PayrollPool.Frequency.MONTHLY, block.timestamp);
        vm.stopPrank();
    }

    function test_transferOwnership_revertsNonOwner() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(alice);
        vm.expectRevert();
        pool.transferOwnership(newAdmin);
    }

    // =========================================================================
    // Pause semantics — claims allowed, accrual frozen, schedule shifts
    // =========================================================================

    function test_pause_freezesAccrual() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH); // 2 periods → 4000
        vm.prank(admin);
        pool.pausePool();

        // No matter how long the pause lasts, nothing new unlocks.
        vm.warp(block.timestamp + 5 * MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), 4_000e18);
    }

    function test_unpause_resumesWhereItStopped() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        // 1.5 months in → 2 periods (4000); next boundary was start + 2*MONTH
        vm.warp(start + MONTH + MONTH / 2);
        assertEq(pool.claimableAmount(alice, address(usdt)), 4_000e18);

        vm.prank(admin);
        pool.pausePool();
        vm.warp(block.timestamp + 10 days);
        vm.prank(admin);
        pool.unpausePool();

        // Still 4000 right after unpause — the paused window granted nothing.
        assertEq(pool.claimableAmount(alice, address(usdt)), 4_000e18);

        // The next boundary shifted by exactly the pause duration.
        vm.warp(start + 2 * MONTH + 10 days - 1);
        assertEq(pool.claimableAmount(alice, address(usdt)), 4_000e18);
        vm.warp(start + 2 * MONTH + 10 days);
        assertEq(pool.claimableAmount(alice, address(usdt)), 6_000e18);
    }

    function test_unpause_scheduledStartInsidePauseWindow_firesAtUnpause() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp + 5 days;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.prank(admin);
        pool.pausePool();

        // The scheduled start passes while paused — nothing unlocks.
        vm.warp(block.timestamp + 20 days);
        assertEq(pool.claimableAmount(alice, address(usdt)), 0);

        // On unpause the start fires immediately (clock-stop semantics).
        vm.prank(admin);
        pool.unpausePool();
        assertEq(pool.claimableAmount(alice, address(usdt)), 1_000e18);
    }

    function test_unpause_futureStartBeyondPause_unchanged() public {
        uint256 start = block.timestamp + 60 days;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.prank(admin);
        pool.pausePool();
        vm.warp(block.timestamp + 10 days);
        vm.prank(admin);
        pool.unpausePool();

        // Start is still in the future relative to unpause — untouched.
        assertEq(pool.nextUnlockTime(alice, address(usdt)), start);
    }

    function test_setAllocation_revertsWhilePaused() public {
        vm.prank(admin);
        pool.pausePool();

        vm.prank(admin);
        vm.expectRevert(PayrollPool.PoolPausedError.selector);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);
    }

    function test_removeAllocation_whilePaused_foldsAtPauseTime() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH); // 2 periods → 2000
        vm.prank(admin);
        pool.pausePool();

        // Removal long into the pause must fold only pre-pause accrual.
        vm.warp(block.timestamp + 3 * MONTH);
        vm.prank(admin);
        pool.removeAllocation(alice, address(usdt));
        assertEq(pool.claimableAmount(alice, address(usdt)), 2_000e18);
    }

    function test_closePool_whilePaused_settlesAtPauseTime() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH); // 2000
        vm.prank(admin);
        pool.pausePool();

        vm.warp(block.timestamp + 2 * MONTH);
        vm.prank(admin);
        pool.closePool();

        assertEq(pool.claimableAmount(alice, address(usdt)), 2_000e18);
        vm.prank(alice);
        pool.claim(address(usdt));
        assertEq(usdt.balanceOf(alice), 2_000e18);
    }

    function test_pauseCycles_accrueOnlyUnpausedTime() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH); // 2 periods → 2000
        assertEq(pool.claimableAmount(alice, address(usdt)), 2_000e18);

        // Cycle 1: one full month paused
        vm.prank(admin);
        pool.pausePool();
        vm.warp(block.timestamp + MONTH);
        vm.prank(admin);
        pool.unpausePool();
        assertEq(pool.claimableAmount(alice, address(usdt)), 2_000e18);

        vm.warp(block.timestamp + MONTH); // one more unpaused month → 3rd period
        assertEq(pool.claimableAmount(alice, address(usdt)), 3_000e18);

        // Cycle 2: 15 days paused
        vm.prank(admin);
        pool.pausePool();
        vm.warp(block.timestamp + 15 days);
        vm.prank(admin);
        pool.unpausePool();
        assertEq(pool.claimableAmount(alice, address(usdt)), 3_000e18);

        vm.warp(block.timestamp + MONTH); // one more unpaused month → 4th period
        assertEq(pool.claimableAmount(alice, address(usdt)), 4_000e18);
    }

    function test_adminWithdraw_whilePaused_usesFrozenCommitted() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 10_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH); // 2000 committed
        vm.prank(admin);
        pool.pausePool();

        // Long pause — committed stays frozen at 2000, so 8000 is withdrawable.
        vm.warp(block.timestamp + 12 * MONTH);
        vm.prank(admin);
        pool.adminWithdraw(address(usdt), 8_000e18);

        vm.prank(admin);
        vm.expectRevert(PayrollPool.AmountExceedsAvailable.selector);
        pool.adminWithdraw(address(usdt), 1);
    }

    // =========================================================================
    // O(1) accounting — claim cost must not grow with edit count
    // =========================================================================

    function test_manyEdits_accrualCorrect_andClaimGasBounded() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, start);

        // 50 edits, one per day. Each fold banks exactly 1 period (1 day < MONTH),
        // and each new tranche front-loads 1 period at its startTime.
        for (uint256 i = 1; i <= 50; i++) {
            vm.warp(start + i * 1 days);
            vm.prank(admin);
            pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);
        }

        // settled = 50 × 1000 (one folded period per edit) + 1000 live front-load
        assertEq(pool.claimableAmount(alice, address(usdt)), 51_000e18);

        // Claim must be O(1): flat cost regardless of the 50-edit history.
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        pool.claim(address(usdt));
        uint256 gasUsed = gasBefore - gasleft();
        assertLt(gasUsed, 200_000);

        assertEq(usdt.balanceOf(alice), 51_000e18);
    }

    // =========================================================================
    // Fuzz tests
    // =========================================================================

    function testFuzz_accrualIsLinear(uint256 amount, uint8 periods) public {
        amount  = bound(amount, 1e6, 1_000_000e18);
        periods = uint8(bound(periods, 1, 24));

        usdt.mint(admin, amount * (uint256(periods) + 1));
        vm.startPrank(admin);
        usdt.approve(address(pool), type(uint256).max);
        pool.depositToken(address(usdt), amount * (uint256(periods) + 1));
        vm.stopPrank();

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), amount, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + uint256(periods) * MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), amount * (uint256(periods) + 1));
    }

    function testFuzz_claimNeverExceedsBalance(uint256 depositAmount, uint256 allocAmount, uint8 periods) public {
        depositAmount = bound(depositAmount, 1e18, 1_000_000e18);
        allocAmount   = bound(allocAmount, 1e6, depositAmount);
        periods       = uint8(bound(periods, 1, 12));

        usdt.mint(admin, depositAmount);
        vm.startPrank(admin);
        usdt.approve(address(pool), depositAmount);
        pool.depositToken(address(usdt), depositAmount);
        pool.setAllocation(alice, address(usdt), allocAmount, PayrollPool.Frequency.MONTHLY, block.timestamp);
        vm.stopPrank();

        vm.warp(block.timestamp + uint256(periods) * MONTH);

        uint256 claimable = pool.claimableAmount(alice, address(usdt));
        if (claimable <= pool.poolBalance(address(usdt))) {
            vm.prank(alice);
            pool.claim(address(usdt));
        }
    }
}
