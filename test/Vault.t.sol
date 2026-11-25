// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { BaseTest } from "./BaseTest.sol";
import { SentinelVault } from "../src/SentinelVault.sol";
import { SentinelModel } from "../src/lib/SentinelModel.sol";

contract VaultTest is BaseTest {
    address internal constant AGENT = address(0xA11CE);
    address internal constant ALICE = address(0xA1);

    function _request(uint256 id, int256[6] memory f) internal {
        vm.prank(PROXY_ADDR);
        vault.requestRiskAssessment(address(reactive), id, f);
    }

    function _apply(uint256 id) internal {
        vm.prank(PROXY_ADDR);
        vault.applyPolicy(address(reactive), id);
    }

    function test_constructorWiring() public view {
        assertEq(uint8(vault.mode()), uint8(SentinelVault.Mode.NORMAL));
        assertEq(vault.MODEL_HASH(), SentinelModel.MODEL_HASH);
        assertEq(vault.DEFENSIVE_THRESHOLD(), 6500);
        assertEq(vault.RECOVERY_THRESHOLD(), 4900);
    }

    function test_requestRequiresProxyAndReactive() public {
        int256[6] memory f = calmFeatures();

        vm.expectRevert();
        vault.requestRiskAssessment(address(reactive), 1, f);

        vm.prank(PROXY_ADDR);
        vm.expectRevert();
        vault.requestRiskAssessment(address(0xBAD), 1, f);

        vm.prank(PROXY_ADDR);
        vault.requestRiskAssessment(address(reactive), 1, f);

        (uint256 tickId, int256[6] memory got, uint64 at, bool scored, bool applied) =
            vault.getRequest(1);
        assertEq(tickId, 1);
        assertEq(got[4], f[4]);
        assertGt(at, 0);
        assertFalse(scored);
        assertFalse(applied);
    }

    function test_scoreMustEqualOnchainInference() public {
        int256[6] memory f = calmFeatures();
        _request(1, f);

        uint16 real = SentinelModel.score(f);
        vm.prank(AGENT);
        vm.expectRevert(
            abi.encodeWithSelector(SentinelVault.ScoreMismatch.selector, real + 1, real)
        );
        vault.submitRiskScore(1, real + 1, SentinelModel.MODEL_HASH);

        vm.prank(AGENT);
        vm.expectRevert(SentinelVault.BadModelHash.selector);
        vault.submitRiskScore(1, real, bytes32(0));

        vm.prank(AGENT);
        vault.submitRiskScore(1, real, SentinelModel.MODEL_HASH);
        assertEq(vault.riskScoreBps(), real);
        assertEq(vault.lastAgent(), AGENT);

        vm.prank(AGENT);
        vm.expectRevert(abi.encodeWithSelector(SentinelVault.AlreadyScored.selector, 1));
        vault.submitRiskScore(1, real, SentinelModel.MODEL_HASH);
    }

    function test_hysteresisAndDepositGate() public {
        vm.deal(ALICE, 10 ether);
        vm.prank(ALICE);
        vault.deposit{ value: 1 ether }();
        assertEq(vault.deposits(ALICE), 1 ether);

        // calm -> normal, deposits allowed
        int256[6] memory calm = calmFeatures();
        uint16 calmScore = SentinelModel.score(calm);
        assertLt(calmScore, 4900);
        _request(1, calm);
        vm.prank(AGENT);
        vault.submitRiskScore(1, calmScore, SentinelModel.MODEL_HASH);
        _apply(1);
        assertEq(uint8(vault.mode()), uint8(SentinelVault.Mode.NORMAL));

        // crash -> defensive, new deposits blocked
        int256[6] memory crash = crashFeatures();
        uint16 crashScore = SentinelModel.score(crash);
        assertGt(crashScore, 6500);
        _request(2, crash);
        vm.prank(AGENT);
        vault.submitRiskScore(2, crashScore, SentinelModel.MODEL_HASH);

        vm.expectEmit(true, false, false, true, address(vault));
        emit SentinelVault.ModeChanged(
            uint8(SentinelVault.Mode.NORMAL), uint8(SentinelVault.Mode.DEFENSIVE)
        );
        _apply(2);
        assertEq(uint8(vault.mode()), uint8(SentinelVault.Mode.DEFENSIVE));

        vm.prank(ALICE);
        vm.expectRevert(SentinelVault.GuardActive.selector);
        vault.deposit{ value: 1 ether }();

        // neutral band keeps the current posture
        int256[6] memory mid = midFeatures();
        uint16 midScore = SentinelModel.score(mid);
        assertGt(midScore, 4900);
        assertLt(midScore, 6500);
        _request(3, mid);
        vm.prank(AGENT);
        vault.submitRiskScore(3, midScore, SentinelModel.MODEL_HASH);
        _apply(3);
        assertEq(uint8(vault.mode()), uint8(SentinelVault.Mode.DEFENSIVE));

        // recovery -> normal again
        int256[6] memory rec = recoveryFeatures();
        uint16 recScore = SentinelModel.score(rec);
        assertLt(recScore, 4900);
        _request(4, rec);
        vm.prank(AGENT);
        vault.submitRiskScore(4, recScore, SentinelModel.MODEL_HASH);
        _apply(4);
        assertEq(uint8(vault.mode()), uint8(SentinelVault.Mode.NORMAL));

        vm.prank(ALICE);
        vault.deposit{ value: 1 ether }();
        assertEq(vault.deposits(ALICE), 2 ether);

        vm.prank(ALICE);
        vault.withdraw(0.5 ether);
        assertEq(vault.deposits(ALICE), 1.5 ether);
    }

    function test_fallbackGoesDefensiveWithoutScore() public {
        _request(7, calmFeatures());
        vm.warp(block.timestamp + 181);

        vm.prank(PROXY_ADDR);
        vault.applyFallback(address(reactive), 7);
        assertEq(uint8(vault.mode()), uint8(SentinelVault.Mode.DEFENSIVE));

        // a late score cannot overwrite the fallback
        uint16 s = SentinelModel.score(calmFeatures());
        vm.prank(AGENT);
        vm.expectRevert(abi.encodeWithSelector(SentinelVault.AlreadyApplied.selector, 7));
        vault.submitRiskScore(7, s, SentinelModel.MODEL_HASH);
    }

    function test_doubleApplyReverts() public {
        int256[6] memory f = calmFeatures();
        _request(1, f);
        uint16 s = SentinelModel.score(f);
        vm.prank(AGENT);
        vault.submitRiskScore(1, s, SentinelModel.MODEL_HASH);
        _apply(1);

        vm.prank(PROXY_ADDR);
        vm.expectRevert(abi.encodeWithSelector(SentinelVault.AlreadyApplied.selector, 1));
        vault.applyPolicy(address(reactive), 1);
    }
}
