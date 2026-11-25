// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { BaseTest } from "./BaseTest.sol";
import { SentinelVault } from "../src/SentinelVault.sol";

/// @notice The demo story, end to end: calm, crash, partial recovery.
///         Every state change below is produced by the reactive contract and a
///         callback; the test only plays the role of the price feed and of the
///         off-chain agent.
contract E2ETest is BaseTest {
    address internal constant ALICE = address(0xA1);

    uint256[21] internal story = [
        200000000000,
        200200000000,
        200039840000,
        200339899760,
        200239729810,
        200399921594,
        200640401500,
        197630795477,
        193678179568,
        188836225079,
        185437173027,
        183211926951,
        183944774659,
        184496608983,
        185142347114,
        185512631808,
        185976413388,
        186534342628,
        186907411313,
        187187772430,
        187374960203
    ];

    function test_storyFullLoop() public {
        vm.deal(ALICE, 10 ether);

        // ---- calm ------------------------------------------------------ //
        for (uint256 i = 0; i < 5; i++) {
            pushTick(story[i]);
        }
        assertEq(sys.callCount(), 0); // window not full yet

        pushTick(story[5]); // sixth tick completes the window
        uint16 calmScore = settle();
        assertLt(calmScore, 4900);
        assertEq(uint8(vault.mode()), uint8(SentinelVault.Mode.NORMAL));

        vm.prank(ALICE);
        vault.deposit{ value: 1 ether }();
        assertEq(vault.deposits(ALICE), 1 ether);

        pushTick(story[6]);
        settle();
        assertEq(uint8(vault.mode()), uint8(SentinelVault.Mode.NORMAL));

        // ---- crash ----------------------------------------------------- //
        pushTick(story[7]);
        uint16 crashScore = settle();
        assertGt(crashScore, 6500);
        assertEq(uint8(vault.mode()), uint8(SentinelVault.Mode.DEFENSIVE));
        assertEq(reactive.lastAppliedRequestId(), 8);

        vm.prank(ALICE);
        vm.expectRevert(SentinelVault.GuardActive.selector);
        vault.deposit{ value: 1 ether }();

        // the neutral band keeps the guard up through the first rebound
        for (uint256 i = 8; i < 13; i++) {
            pushTick(story[i]);
            settle();
        }
        assertGt(vault.riskScoreBps(), 4900);
        assertLt(vault.riskScoreBps(), 6500);
        assertEq(uint8(vault.mode()), uint8(SentinelVault.Mode.DEFENSIVE));

        // ---- recovery -------------------------------------------------- //
        for (uint256 i = 13; i < 21; i++) {
            pushTick(story[i]);
            settle();
        }
        assertLt(vault.riskScoreBps(), 4900);
        assertEq(uint8(vault.mode()), uint8(SentinelVault.Mode.NORMAL));

        vm.prank(ALICE);
        vault.deposit{ value: 1 ether }();
        assertEq(vault.deposits(ALICE), 2 ether);
    }

    function test_everyRequestIsAnsweredExactlyOnce() public {
        for (uint256 i = 0; i < 8; i++) {
            pushTick(story[i]);
            settle();
        }
        // 3 requests (ticks 6, 7, 8) and 3 policy callbacks
        assertEq(sys.callCount(), 6);
        assertEq(vault.lastRequestId(), 8);

        // replaying the last score log must not apply the policy twice
        uint256 before = sys.callCount();
        deliverScore(8);
        assertEq(sys.callCount(), before);
    }
}
