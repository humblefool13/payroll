// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {PayrollFactory} from "../src/PayrollFactory.sol";
import {PayrollPool} from "../src/PayrollPool.sol";

contract PayrollFactoryTest is Test {
    PayrollFactory factory;

    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address fakeToken = makeAddr("fakeToken");

    function setUp() public {
        vm.prank(owner);
        factory = new PayrollFactory(owner);
    }

    // -------------------------------------------------------------------------
    // Fee management
    // -------------------------------------------------------------------------

    function test_setFeeBps() public {
        vm.prank(owner);
        factory.setFeeBps(50);
        assertEq(factory.feeBps(), 50);
    }

    function test_setFeeBps_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit PayrollFactory.FeeBpsSet(0, 75);
        factory.setFeeBps(75);
    }

    function test_setFeeBps_revertsAboveCap() public {
        uint256 above = factory.MAX_FEE_BPS() + 1;
        vm.prank(owner);
        vm.expectRevert(PayrollFactory.FeeTooHigh.selector);
        factory.setFeeBps(above);
    }

    function test_setFeeBps_revertsNonOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        factory.setFeeBps(10);
    }

    function test_setFeeBps_atCap() public {
        uint256 cap = factory.MAX_FEE_BPS();
        vm.prank(owner);
        factory.setFeeBps(cap);
        assertEq(factory.feeBps(), cap);
    }

    // -------------------------------------------------------------------------
    // Token whitelist
    // -------------------------------------------------------------------------

    function test_ethWhitelistedByDefault() public view {
        assertTrue(factory.tokenWhitelisted(address(0)));
    }

    function test_whitelistToken() public {
        vm.prank(owner);
        factory.whitelistToken(fakeToken);
        assertTrue(factory.tokenWhitelisted(fakeToken));
    }

    function test_whitelistToken_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit PayrollFactory.TokenWhitelisted(fakeToken);
        factory.whitelistToken(fakeToken);
    }

    function test_whitelistToken_revertsIfAlreadyListed() public {
        vm.startPrank(owner);
        factory.whitelistToken(fakeToken);
        vm.expectRevert(PayrollFactory.AlreadyWhitelisted.selector);
        factory.whitelistToken(fakeToken);
        vm.stopPrank();
    }

    function test_whitelistToken_revertsNonOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        factory.whitelistToken(fakeToken);
    }

    // -------------------------------------------------------------------------
    // Pool deployment
    // -------------------------------------------------------------------------

    function test_deployPool() public {
        vm.prank(user1);
        address pool = factory.deployPool();
        assertTrue(pool != address(0));
        assertEq(PayrollPool(pool).owner(), user1);
        assertEq(PayrollPool(pool).factory(), address(factory));
    }

    function test_deployPool_registersAdminPool() public {
        vm.prank(user1);
        address pool = factory.deployPool();
        address[] memory pools = factory.getAdminPools(user1);
        assertEq(pools.length, 1);
        assertEq(pools[0], pool);
    }

    function test_deployPool_setsIsDeployedPool() public {
        vm.prank(user1);
        address pool = factory.deployPool();
        assertTrue(factory.isDeployedPool(pool));
    }

    function test_deployPool_emitsEvent() public {
        vm.prank(user1);
        vm.expectEmit(false, true, false, false);
        emit PayrollFactory.PoolDeployed(address(0), user1);
        factory.deployPool();
    }

    function test_deployPool_multiplePoolsForSameAdmin() public {
        vm.startPrank(user1);
        factory.deployPool();
        factory.deployPool();
        factory.deployPool();
        vm.stopPrank();
        assertEq(factory.getAdminPools(user1).length, 3);
    }

    function test_deployPool_differentAdmins() public {
        vm.prank(user1);
        factory.deployPool();
        vm.prank(user2);
        factory.deployPool();
        assertEq(factory.getAdminPools(user1).length, 1);
        assertEq(factory.getAdminPools(user2).length, 1);
    }

    // -------------------------------------------------------------------------
    // Beneficiary registry
    // -------------------------------------------------------------------------

    function test_registerBeneficiary_onlyFromPool() public {
        vm.prank(user1);
        address pool = factory.deployPool();

        vm.prank(user1);
        vm.expectRevert(PayrollFactory.OnlyPool.selector);
        factory.registerBeneficiary(user2, pool);
    }

    function test_registerBeneficiary_rejectsRoguePool() public {
        // Attacker calls registerBeneficiary with an address never deployed by this factory.
        address roguePool = makeAddr("roguePool");
        vm.prank(roguePool);
        vm.expectRevert(PayrollFactory.NotAValidPool.selector);
        factory.registerBeneficiary(user2, roguePool);
    }

    function test_recordFee_rejectsRoguePool() public {
        address roguePool = makeAddr("roguePool");
        vm.prank(roguePool);
        vm.expectRevert(PayrollFactory.NotAValidPool.selector);
        factory.recordFee(address(0), 1 ether);
    }

    function test_isDeployedPool_falseForUnknown() public {
        assertFalse(factory.isDeployedPool(makeAddr("rogue")));
    }

    function test_beneficiaryPools_registeredViaAllocation() public {
        vm.prank(owner);
        factory.whitelistToken(fakeToken);

        vm.prank(user1);
        address pool = factory.deployPool();

        vm.prank(user1);
        PayrollPool(pool).setAllocation(
            user2,
            fakeToken,
            1000e18,
            PayrollPool.Frequency.MONTHLY,
            block.timestamp + 1 days
        );

        address[] memory bPools = factory.getBeneficiaryPools(user2);
        assertEq(bPools.length, 1);
        assertEq(bPools[0], pool);
    }

    function test_beneficiaryPools_notDuplicated() public {
        vm.prank(owner);
        factory.whitelistToken(fakeToken);

        vm.prank(user1);
        address pool = factory.deployPool();

        vm.startPrank(user1);
        PayrollPool(pool).setAllocation(
            user2,
            fakeToken,
            1000e18,
            PayrollPool.Frequency.MONTHLY,
            block.timestamp + 1 days
        );
        // Second allocation for same beneficiary in same pool — factory registered only once.
        PayrollPool(pool).setAllocation(
            user2,
            address(0),
            1 ether,
            PayrollPool.Frequency.WEEKLY,
            block.timestamp + 1 days
        );
        vm.stopPrank();

        assertEq(factory.getBeneficiaryPools(user2).length, 1);
    }

    // -------------------------------------------------------------------------
    // Fee collection
    // -------------------------------------------------------------------------

    function test_collectFees_ETH() public {
        vm.prank(owner);
        factory.setFeeBps(100); // 1%

        vm.prank(user1);
        address pool = factory.deployPool();

        vm.prank(user1);
        PayrollPool(pool).setAllocation(
            user2,
            address(0),
            1 ether,
            PayrollPool.Frequency.WEEKLY,
            block.timestamp
        );

        vm.deal(user1, 10 ether);
        vm.prank(user1);
        PayrollPool(pool).depositETH{value: 5 ether}();

        vm.warp(block.timestamp + 7 days);

        vm.prank(user2);
        PayrollPool(pool).claim(address(0));

        uint256 accrued = factory.accruedFees(address(0));
        assertGt(accrued, 0);

        address payable recipient = payable(makeAddr("treasury"));
        vm.prank(owner);
        factory.collectFees(address(0), recipient);

        assertEq(factory.accruedFees(address(0)), 0);
        assertEq(recipient.balance, accrued);
    }

    function test_collectFees_revertsNonOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        factory.collectFees(address(0), payable(user1));
    }

    function test_collectFees_revertsNothingToCollect() public {
        vm.prank(owner);
        vm.expectRevert(PayrollFactory.NothingToCollect.selector);
        factory.collectFees(address(0), payable(owner));
    }

    // -------------------------------------------------------------------------
    // SC-21: getWhitelistedTokens includes ETH
    // -------------------------------------------------------------------------

    function test_getWhitelistedTokens_includesETH() public view {
        address[] memory tokens = factory.getWhitelistedTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(0));
    }

    function test_getWhitelistedTokens_includesAddedTokens() public {
        vm.prank(owner);
        factory.whitelistToken(fakeToken);
        address[] memory tokens = factory.getWhitelistedTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(0));
        assertEq(tokens[1], fakeToken);
    }

    // -------------------------------------------------------------------------
    // SC-07: recordFee rejects ETH for ERC-20 calls
    // -------------------------------------------------------------------------

    function test_unregisterBeneficiary_rejectsRoguePool() public {
        address roguePool = makeAddr("roguePool");
        vm.prank(roguePool);
        vm.expectRevert(PayrollFactory.NotAValidPool.selector);
        factory.unregisterBeneficiary(user2, roguePool);
    }

    function test_unregisterBeneficiary_onlyFromPool() public {
        vm.prank(user1);
        address pool = factory.deployPool();

        vm.prank(user1);
        vm.expectRevert(PayrollFactory.OnlyPool.selector);
        factory.unregisterBeneficiary(user2, pool);
    }

    function test_recordFee_revertsETHValueForERC20() public {
        vm.prank(user1);
        address pool = factory.deployPool();

        // Simulate a buggy pool calling recordFee for an ERC-20 but accidentally sending ETH.
        vm.deal(pool, 1 ether);
        vm.prank(pool);
        vm.expectRevert(PayrollFactory.ETHValueMismatch.selector);
        factory.recordFee{value: 1 ether}(fakeToken, 1 ether);
    }
}
