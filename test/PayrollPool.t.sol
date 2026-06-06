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

    function test_deposit_revertsOnClosed() public {
        vm.prank(admin);
        pool.closePool();
        vm.prank(admin);
        vm.expectRevert(PayrollPool.PoolClosedError.selector);
        pool.depositToken(address(usdt), 1000e18);
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
        pool.setAllocation(alice, address(usdt), 6_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);

        vm.warp(block.timestamp + MONTH); // 6000 committed

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

        // After 2 months: 4000 accrued in tranche 0
        vm.warp(start + 2 * MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), 4_000e18);

        // Admin raises rate to 3000/month starting now
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 3_000e18, PayrollPool.Frequency.MONTHLY, block.timestamp);

        // Tranche 0 sealed at 2*MONTH → 4000 still owed; tranche 1 not yet elapsed
        assertEq(pool.claimableAmount(alice, address(usdt)), 4_000e18);

        // 1 month into tranche 1 → 4000 + 3000 = 7000
        vm.warp(block.timestamp + MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), 7_000e18);

        // 2nd month in tranche 1 → 4000 + 6000 = 10000
        vm.warp(block.timestamp + MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), 10_000e18);
    }

    function test_editAllocation_newStartInFuture_gapIsNotAccrued() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH); // 2000 accrued in tranche 0

        // New tranche starts 30 days from now (gap between old endTime and new startTime)
        uint256 newStart = block.timestamp + MONTH;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 3_000e18, PayrollPool.Frequency.MONTHLY, newStart);

        // During the gap — still only 2000 from tranche 0
        vm.warp(newStart - 1);
        assertEq(pool.claimableAmount(alice, address(usdt)), 2_000e18);

        // 1 period after new tranche start → 2000 + 3000 = 5000
        vm.warp(newStart + MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), 5_000e18);
    }

    function test_editAllocation_partialPeriodNotCounted() public {
        // Tranche sealed mid-period: floor division must discard the partial period.
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, start);

        // Seal halfway through month 2 → only 1 full period counted in tranche 0
        vm.warp(start + MONTH + MONTH / 2);
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 500e18, PayrollPool.Frequency.MONTHLY, block.timestamp);

        // Tranche 0: 1 full period (floor of 1.5 months) → 1000
        // Tranche 1: 0 full periods elapsed yet → 0
        assertEq(pool.claimableAmount(alice, address(usdt)), 1_000e18);
    }

    function test_claimedAmountNotDoubleCountedAfterEdit() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + 2 * MONTH); // 2000 accrued

        vm.prank(alice);
        pool.claim(address(usdt)); // claims 2000; _claimed = 2000

        // Admin changes rate
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 500e18, PayrollPool.Frequency.MONTHLY, block.timestamp);

        // Nothing extra immediately
        assertEq(pool.claimableAmount(alice, address(usdt)), 0);

        // 1 period in new tranche
        vm.warp(block.timestamp + MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), 500e18);
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

        assertEq(pool.claimableAmount(alice, address(usdt)), 2_000e18);

        vm.warp(block.timestamp + 10 * MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), 2_000e18);
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
        assertEq(usdt.balanceOf(alice), 6_000e18); // no fee set
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

        assertEq(usdt.balanceOf(alice), 2_000e18);
        assertEq(pool.claimableAmount(alice, address(usdt)), 0);
    }

    function test_claim_accumulatesOverMultiplePeriods() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 1_000e18, PayrollPool.Frequency.WEEKLY, start);

        vm.warp(start + 4 * WEEK);
        assertEq(pool.claimableAmount(alice, address(usdt)), 4_000e18);

        vm.prank(alice);
        pool.claim(address(usdt));
        assertEq(usdt.balanceOf(alice), 4_000e18);

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

        assertEq(usdt.balanceOf(alice), 9_900e18);
        assertEq(factory.accruedFees(address(usdt)), 100e18);
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
        assertEq(alice.balance - balBefore, 1 ether);
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

    function test_claim_revertsWhenPaused() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH);
        vm.prank(admin);
        pool.pausePool();

        vm.prank(alice);
        vm.expectRevert(PayrollPool.PoolPausedError.selector);
        pool.claim(address(usdt));
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
        assertEq(usdt.balanceOf(alice), 2_000e18);
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

        assertEq(usdt.balanceOf(alice), 2_000e18);
        assertEq(usdt.balanceOf(bob),   1_000e18);
    }

    function test_committedAmountBlocksAdminWithdraw() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 5_000e18);

        uint256 start = block.timestamp;
        vm.startPrank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);
        pool.setAllocation(bob,   address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);
        vm.stopPrank();

        vm.warp(start + MONTH); // 4000 committed total

        vm.prank(admin);
        vm.expectRevert(PayrollPool.AmountExceedsAvailable.selector);
        pool.adminWithdraw(address(usdt), 2_000e18);

        vm.prank(admin);
        pool.adminWithdraw(address(usdt), 1_000e18);
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
        assertEq(pool.claimableAmount(alice, address(usdt)), 1_500e18);
    }

    function test_quarterlyFrequency() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 12_000e18, PayrollPool.Frequency.QUARTERLY, start);

        vm.warp(start + 2 * QUARTER);
        assertEq(pool.claimableAmount(alice, address(usdt)), 24_000e18);
    }

    function test_futureStartTime_nothingBeforeStart() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 100_000e18);

        uint256 start = block.timestamp + 7 days;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start - 1);
        assertEq(pool.claimableAmount(alice, address(usdt)), 0);

        vm.warp(start); // exactly at start — 0 full periods elapsed
        assertEq(pool.claimableAmount(alice, address(usdt)), 0);

        vm.warp(start + MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), 2_000e18);
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
        assertEq(usdt.balanceOf(alice), 4_000e18);
    }

    function test_closePool_adminCanWithdrawExcess() public {
        vm.prank(admin);
        pool.depositToken(address(usdt), 10_000e18);

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), 2_000e18, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + MONTH); // 2000 committed to alice
        vm.prank(admin);
        pool.closePool();

        uint256 balBefore = usdt.balanceOf(admin);
        vm.prank(admin);
        pool.adminWithdraw(address(usdt), 8_000e18);
        assertEq(usdt.balanceOf(admin) - balBefore, 8_000e18);
    }

    function test_closePool_revertsIfAlreadyClosed() public {
        vm.prank(admin);
        pool.closePool();
        vm.prank(admin);
        vm.expectRevert(PayrollPool.PoolAlreadyClosed.selector);
        pool.closePool();
    }

    function test_closePool_revertsNewDeposit() public {
        vm.prank(admin);
        pool.closePool();
        vm.prank(admin);
        vm.expectRevert(PayrollPool.PoolClosedError.selector);
        pool.depositToken(address(usdt), 1000e18);
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
        assertEq(usdt.balanceOf(alice), 2_000e18);
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
        assertEq(usdt.balanceOf(alice), 2_000e18);
    }

    // =========================================================================
    // Fuzz tests
    // =========================================================================

    function testFuzz_accrualIsLinear(uint256 amount, uint8 periods) public {
        amount  = bound(amount, 1e6, 1_000_000e18);
        periods = uint8(bound(periods, 1, 24));

        usdt.mint(admin, amount * periods);
        vm.startPrank(admin);
        usdt.approve(address(pool), type(uint256).max);
        pool.depositToken(address(usdt), amount * periods);
        vm.stopPrank();

        uint256 start = block.timestamp;
        vm.prank(admin);
        pool.setAllocation(alice, address(usdt), amount, PayrollPool.Frequency.MONTHLY, start);

        vm.warp(start + uint256(periods) * MONTH);
        assertEq(pool.claimableAmount(alice, address(usdt)), amount * periods);
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
