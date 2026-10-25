// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AmplifiLendingPool} from "../src/AmplifiLendingPool.sol";
import {MockUSDC} from "./AmplifiLendingPool.t.sol";

contract RepaymentSequenceTest is Test {
    AmplifiLendingPool pool;
    MockUSDC token;
    address alice = makeAddr("alice lender");
    address bob = makeAddr("bob lender");
    address borrowerA = makeAddr("borrower A");
    address borrowerB = makeAddr("borrower B");
    address fees = makeAddr("fees");
    uint256[4] modelDebt;
    uint256[4] modelPrincipal;
    uint256 modelFees;
    uint256 paid;
    uint256 collected;
    uint256 withdrawn;

    function setUp() public {
        token = new MockUSDC();
        // A constant 10% rate lets the reference model use dollars and elapsed time, not debt shares.
        pool = new AmplifiLendingPool(
            address(token), address(this), address(this), 1000, 8500, 1000, 1000, new address[](0)
        );
        pool.setBorrowPaused(false);
        pool.setProtocolFee(1000);
    }

    function test_multipleBlocksStaggeredLoansRepaymentsAndLenderExits() public {
        _deposit(alice, 100_000e6);
        _borrow(1, borrowerA, 10_000e6);
        _advance(36 days + 12 hours, 1_000);
        assertEq(modelDebt[1], 10_100e6);

        _deposit(bob, 20_000e6);
        _borrow(2, borrowerB, 10_000e6);
        assertApproxEqAbs(pool.loanDebt(2), 10_000e6, 1);
        _repay(1, borrowerA, 50e6);
        assertEq(pool.loanPrincipal(1), 10_000e6, "interest-only payment preserves principal");

        _advance(18 days + 6 hours, 500);
        _repay(1, borrowerA, 2_000e6);
        assertLt(pool.loanPrincipal(1), 10_000e6);
        _repay(2, borrowerB, 1_000e6);
        _borrow(3, borrowerA, 5_000e6);

        _advance(73 days, 2_000);
        uint256 valueBefore = pool.totalAssets();
        uint256 feeAmount = pool.protocolFeesAccrued();
        pool.collectProtocolFees(fees, feeAmount);
        collected += feeAmount;
        modelFees -= feeAmount;
        assertEq(pool.totalAssets(), valueBefore, "collecting reserved fees preserves lender assets");
        _assertAccounting();

        uint256 bobPartialShares = pool.balanceOf(bob) / 3;
        vm.prank(bob);
        withdrawn += pool.withdraw(bobPartialShares);
        _assertAccounting();
        _repay(3, borrowerA, 700e6);
        _repay(2, borrowerB, 2_000e6);

        _advance(7 days, 300);
        _repay(1, borrowerA, pool.loanDebt(1) + 10e6);
        _repay(2, borrowerB, pool.loanDebt(2));
        _repay(3, borrowerA, pool.loanDebt(3));
        assertEq(pool.totalBorrowShares(), 0);
        assertEq(pool.totalBorrowAssets(), 0);
        assertEq(pool.borrowIndex(), 1e27);
        assertEq(pool.totalBadDebtRealized(), 0);

        uint256 finalFees = pool.protocolFeesAccrued();
        pool.collectProtocolFees(fees, finalFees);
        collected += finalFees;
        uint256 aliceShares = pool.balanceOf(alice);
        uint256 bobShares = pool.balanceOf(bob);
        vm.prank(alice);
        withdrawn += pool.withdraw(aliceShares);
        vm.prank(bob);
        withdrawn += pool.withdraw(bobShares);
        assertEq(pool.totalSupply(), 0);
        assertEq(token.balanceOf(fees), collected);
        assertEq(token.balanceOf(address(pool)) + withdrawn + collected, 120_000e6 - 25_000e6 + paid);
        assertLe(token.balanceOf(address(pool)), 10, "virtual-share interest and rounding below ten microdollars");
        assertGt(withdrawn, 120_000e6, "lenders receive earned interest");
    }

    function _deposit(address lender, uint256 amount) internal {
        token.mint(lender, amount);
        vm.startPrank(lender);
        token.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();
        _assertAccounting();
    }

    function _borrow(uint256 id, address borrower, uint256 amount) internal {
        pool.borrow(id, amount, borrower);
        modelDebt[id] = amount;
        modelPrincipal[id] = amount;
        _assertAccounting();
    }

    function _advance(uint256 elapsed, uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + elapsed);
        for (uint256 id = 1; id <= 3; ++id) {
            uint256 interestNumerator = modelDebt[id] * elapsed;
            modelDebt[id] += (interestNumerator + 10 * 365 days - 1) / (10 * 365 days);
        }
        pool.accrueInterest();
        emit log_named_uint("block", block.number);
        emit log_named_uint("timestamp", block.timestamp);
        _assertAccounting();
    }

    function _repay(uint256 id, address borrower, uint256 sent) internal {
        uint256 sibling = id == 2 ? 1 : 2;
        uint256 siblingDebt = pool.loanDebt(sibling);
        token.mint(borrower, sent);
        uint256 beforeBalance = token.balanceOf(borrower);
        vm.startPrank(borrower);
        pool.beginRepay(id);
        token.transfer(address(pool), sent);
        pool.repay(id, sent);
        vm.stopPrank();
        uint256 received = beforeBalance - token.balanceOf(borrower);
        paid += received;
        uint256 interest = modelDebt[id] - modelPrincipal[id];
        uint256 interestPaid = received < interest ? received : interest;
        modelFees += interestPaid / 10;
        if (received >= modelDebt[id] || pool.loanShares(id) == 0) {
            assertApproxEqAbs(received, modelDebt[id], 10);
            modelDebt[id] = 0;
            modelPrincipal[id] = 0;
        } else {
            modelDebt[id] -= received;
            modelPrincipal[id] -= received - interestPaid;
        }
        assertEq(pool.loanDebt(sibling), siblingDebt, "repayment cannot change sibling debt");
        emit log_named_uint("repaid loan", id);
        emit log_named_uint("net tokens paid", received);
        _assertAccounting();
    }

    function _assertAccounting() internal view {
        uint256 totalDebt;
        uint256 totalShares;
        for (uint256 id = 1; id <= 3; ++id) {
            // The dollar model rounds each accrual; the pool rounds indexed shares instead.
            assertApproxEqAbs(pool.loanDebt(id), modelDebt[id], 10, "loan debt versus independent dollar model");
            assertApproxEqAbs(pool.loanPrincipal(id), modelPrincipal[id], 10, "remaining principal");
            totalDebt += modelDebt[id];
            totalShares += pool.loanShares(id);
        }
        assertEq(pool.totalBorrowShares(), totalShares);
        assertApproxEqAbs(pool.totalBorrowAssets(), totalDebt, 30);
        assertApproxEqAbs(pool.protocolFeesAccrued(), modelFees, 10);
        assertApproxEqAbs(pool.totalAssets(), token.balanceOf(address(pool)) + totalDebt - modelFees, 40);
    }
}
