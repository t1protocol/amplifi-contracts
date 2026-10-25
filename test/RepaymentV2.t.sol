// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AmplifiLendingPool} from "../src/AmplifiLendingPool.sol";
import {MockUSDC} from "./AmplifiLendingPool.t.sol";

contract RepaymentWallet {
    function pay(AmplifiLendingPool pool, MockUSDC token, uint256 id, uint256 transferred, uint256 claimed) external {
        pool.beginRepay(id);
        token.transfer(address(pool), transferred);
        pool.repay(id, claimed);
    }

    function payFull(AmplifiLendingPool pool, MockUSDC token, uint256 id, uint256 amount) external {
        pool.beginRepay(id);
        token.transfer(address(pool), amount);
        pool.repayFull(id, amount);
    }
}

contract TaxedRepaymentToken is MockUSDC {
    bool public tax;

    function enableTax() external {
        tax = true;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (tax && from != address(0) && to != address(0) && amount != 0) {
            super._update(from, address(0), 1);
            super._update(from, to, amount - 1);
        } else {
            super._update(from, to, amount);
        }
    }
}

contract RepaymentV2Test is Test {
    AmplifiLendingPool pool;
    MockUSDC token;
    address wallet = makeAddr("wallet");
    address other = makeAddr("other");
    uint256 constant SIGNER_KEY = 0x123456;

    function setUp() public {
        token = new MockUSDC();
        pool = new AmplifiLendingPool(
            address(token), address(this), address(this), 2000, 8500, 20000, 100000, new address[](0)
        );
        pool.setBorrowPaused(false);
        token.mint(address(this), 1_000_000e6);
        token.approve(address(pool), type(uint256).max);
        pool.deposit(1_000_000e6);
        pool.setSettlementSigner(vm.addr(SIGNER_KEY));
    }

    function _pay(uint256 id, uint256 amount) internal returns (uint256 paid) {
        address borrower = pool.loanWallet(id);
        token.mint(borrower, amount);
        uint256 balance = token.balanceOf(borrower);
        vm.startPrank(borrower);
        pool.beginRepay(id);
        token.transfer(address(pool), amount);
        pool.repay(id, amount);
        vm.stopPrank();
        return balance - token.balanceOf(borrower);
    }

    function _signature(uint256 id, uint256 amount, uint256 cap, uint256 nonce, uint256 deadline, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AmplifiLendingPool"),
                keccak256("2"),
                block.chainid,
                address(pool)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domain,
                keccak256(
                    abi.encode(pool.LOSS_SETTLEMENT_TYPEHASH(), id, pool.loanWallet(id), amount, cap, nonce, deadline)
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_phantomPaymentCannotUseDonation() public {
        pool.borrow(1, 100e6, wallet);
        token.mint(address(this), 100e6);
        token.transfer(address(pool), 100e6);
        vm.startPrank(wallet);
        vm.expectRevert(AmplifiLendingPool.RepaymentNotStarted.selector);
        pool.repay(1, 100e6);
        pool.beginRepay(1);
        vm.expectRevert(AmplifiLendingPool.RepaymentAmountMismatch.selector);
        pool.repay(1, 100e6);
        vm.stopPrank();
        assertEq(pool.loanDebt(1), 100e6);
        assertEq(pool.totalBadDebtRealized(), 0);
    }

    function test_newDeploymentCannotBorrowBeforeOwnerUnpauses() public {
        AmplifiLendingPool fresh =
            new AmplifiLendingPool(address(token), address(this), address(this), 0, 8500, 0, 0, new address[](0));
        assertTrue(fresh.borrowPaused());
        assertEq(fresh.repaymentVersion(), 2);
        vm.expectRevert(AmplifiLendingPool.BorrowPaused.selector);
        fresh.borrow(1, 1, wallet);
    }

    function test_pushFeeOnTransferMismatchRollsBack() public {
        TaxedRepaymentToken taxed = new TaxedRepaymentToken();
        AmplifiLendingPool fresh =
            new AmplifiLendingPool(address(taxed), address(this), address(this), 0, 8500, 0, 0, new address[](0));
        fresh.setBorrowPaused(false);
        taxed.mint(address(this), 100e6);
        taxed.approve(address(fresh), 100e6);
        fresh.deposit(100e6);
        RepaymentWallet batch = new RepaymentWallet();
        fresh.borrow(1, 50e6, address(batch));
        taxed.enableTax();
        vm.expectRevert(AmplifiLendingPool.RepaymentAmountMismatch.selector);
        batch.pay(fresh, taxed, 1, 50e6, 50e6);
        assertEq(taxed.balanceOf(address(batch)), 50e6);
        assertEq(taxed.balanceOf(address(fresh)), 50e6);
        assertEq(fresh.loanDebt(1), 50e6);
    }

    function test_failedAtomicBatchRollsBackTransferAndCheckpoint() public {
        RepaymentWallet batch = new RepaymentWallet();
        pool.borrow(1, 100e6, address(batch));
        uint256 cash = token.balanceOf(address(pool));
        vm.expectRevert(AmplifiLendingPool.RepaymentAmountMismatch.selector);
        batch.pay(pool, token, 1, 40e6, 41e6);
        assertEq(token.balanceOf(address(pool)), cash);
        assertEq(token.balanceOf(address(batch)), 100e6);
        assertEq(pool.loanDebt(1), 100e6);
        batch.pay(pool, token, 1, 40e6, 40e6);
        assertEq(pool.loanDebt(1), 60e6);
    }

    function test_signatureBoundToChain() public {
        pool.borrow(1, 100e6, wallet);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signature(1, 0, 100e6, 1, deadline, SIGNER_KEY);
        vm.chainId(block.chainid + 1);
        vm.startPrank(wallet);
        pool.beginRepay(1);
        vm.expectRevert(AmplifiLendingPool.InvalidSettlementPermit.selector);
        pool.settleLoss(1, 0, 100e6, 1, deadline, sig);
        vm.stopPrank();
    }

    function test_lossReceiptEmitsPaymentBeforeWriteoff() public {
        pool.borrow(1, 100e6, wallet);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signature(1, 40e6, 60e6, 1, deadline, SIGNER_KEY);
        vm.startPrank(wallet);
        pool.beginRepay(1);
        token.transfer(address(pool), 40e6);
        vm.expectEmit(true, true, false, true, address(pool));
        emit AmplifiLendingPool.RepaymentApplied(1, wallet, 40e6, 40e6, 0, 60e6, 60e6);
        vm.expectEmit(true, false, false, true, address(pool));
        emit AmplifiLendingPool.LoanWrittenOff(1, 60e6, 0, 0);
        pool.settleLoss(1, 40e6, 60e6, 1, deadline, sig);
        vm.stopPrank();
    }

    function test_terminalLossCreditsExactSubSharePayment() public {
        pool.borrow(1, 100e6, wallet);
        vm.warp(block.timestamp + 365 days);
        uint256 debt = pool.loanDebt(1);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signature(1, 1, debt - 1, 1, deadline, SIGNER_KEY);
        uint256 walletBefore = token.balanceOf(wallet);
        vm.startPrank(wallet);
        pool.beginRepay(1);
        token.transfer(address(pool), 1);
        vm.expectEmit(true, true, false, true, address(pool));
        emit AmplifiLendingPool.RepaymentApplied(1, wallet, 1, 0, 1, 100e6, debt - 1);
        pool.settleLoss(1, 1, debt - 1, 1, deadline, sig);
        vm.stopPrank();
        assertEq(token.balanceOf(wallet), walletBefore - 1);
        assertEq(pool.totalBadDebtRealized(), debt - 1);
        assertEq(pool.loanDebt(1), 0);
        assertEq(pool.borrowIndex(), 1e27);
    }

    function test_checkpointCannotBeReusedOrChangedToSibling() public {
        pool.borrow(1, 100e6, wallet);
        pool.borrow(2, 100e6, wallet);
        vm.startPrank(wallet);
        pool.beginRepay(1);
        token.transfer(address(pool), 40e6);
        vm.expectRevert(AmplifiLendingPool.RepaymentNotStarted.selector);
        pool.repay(2, 40e6);
        pool.repay(1, 40e6);
        vm.expectRevert(AmplifiLendingPool.RepaymentNotStarted.selector);
        pool.repay(1, 40e6);
        vm.stopPrank();
        assertEq(pool.loanDebt(1), 60e6);
        assertEq(pool.loanDebt(2), 100e6);
    }

    function test_checkpointBlocksPoolCashMutations() public {
        pool.borrow(1, 100e6, wallet);
        vm.prank(wallet);
        pool.beginRepay(1);
        vm.expectRevert(AmplifiLendingPool.RepaymentInProgress.selector);
        pool.deposit(1);
        vm.expectRevert(AmplifiLendingPool.RepaymentInProgress.selector);
        pool.borrow(2, 1, other);
        vm.expectRevert(AmplifiLendingPool.RepaymentInProgress.selector);
        pool.withdrawAssets(1);
        vm.expectRevert(AmplifiLendingPool.RepaymentInProgress.selector);
        pool.writeOff(1, 100e6);
        vm.prank(other);
        vm.expectRevert(AmplifiLendingPool.RepaymentInProgress.selector);
        pool.beginRepay(1);
    }

    function test_amountMustEqualObservedDelta() public {
        pool.borrow(1, 100e6, wallet);
        vm.startPrank(wallet);
        pool.beginRepay(1);
        token.transfer(address(pool), 40e6);
        vm.expectRevert(AmplifiLendingPool.RepaymentAmountMismatch.selector);
        pool.repay(1, 41e6);
        vm.expectRevert(AmplifiLendingPool.RepaymentAmountMismatch.selector);
        pool.repay(1, 39e6);
        pool.repay(1, 40e6);
        vm.stopPrank();
    }

    function test_partialPaysInterestFirstAndPreservesSiblingPrincipal() public {
        pool.borrow(1, 100e6, wallet);
        vm.warp(block.timestamp + 365 days);
        pool.borrow(2, 40e6, other);
        uint256 debt1 = pool.loanDebt(1);
        uint256 debt2 = pool.loanDebt(2);
        uint256 interest = debt1 - 100e6;
        uint256 paid = _pay(1, interest / 2);
        assertEq(pool.loanPrincipal(1), 100e6);
        assertEq(pool.loanDebt(2), debt2);
        assertGe(pool.loanDebt(1), 100e6);
        assertApproxEqAbs(pool.loanDebt(1), debt1 - paid, 1);
    }

    function test_quoteEqualsAccrualAndTransferDoesNotRepricePastInterest() public {
        pool.borrow(1, 900_000e6, wallet);
        vm.warp(block.timestamp + 365 days);
        uint256 debt = pool.loanDebt(1);
        uint256 assets = pool.totalAssets();
        pool.accrueInterest();
        assertEq(pool.loanDebt(1), debt);
        assertEq(pool.totalAssets(), assets);
        assertEq(_pay(1, debt), debt);
        assertEq(pool.totalBorrowAssets(), 0);
        assertEq(pool.totalBorrowShares(), 0);
        assertEq(pool.totalAssets(), assets);
    }

    function test_overpaymentReturnsToBorrower() public {
        pool.borrow(1, 100e6, wallet);
        assertEq(_pay(1, 120e6), 100e6);
        assertEq(pool.loanDebt(1), 0);
    }

    function test_delayedCloseUsesBoundedOverpaymentAndRefundsExcess() public {
        pool.borrow(1, 1_000e6, wallet);
        uint256 quotedDebt = pool.loanDebt(1);
        uint256 horizon = 300;
        uint256 yearBps = 10_000 * 365 days;
        uint256 denominator = yearBps - pool.MAX_RATE_CAP_BPS() * horizon;
        uint256 bound = (quotedDebt * yearBps + denominator - 1) / denominator;

        pool.setRateParams(1_000_000, 8500, 1_000_000, 1_000_000);
        vm.warp(block.timestamp + horizon);
        uint256 executionDebt = pool.loanDebt(1);
        assertGt(executionDebt, quotedDebt);
        assertGt(bound, executionDebt);

        token.mint(wallet, bound);
        uint256 walletBalance = token.balanceOf(wallet);
        vm.startPrank(wallet);
        pool.beginRepay(1);
        token.transfer(address(pool), bound);
        assertEq(pool.repayFull(1, bound), 0);
        vm.stopPrank();
        uint256 paid = walletBalance - token.balanceOf(wallet);

        assertEq(paid, executionDebt);
        assertEq(pool.loanDebt(1), 0);
        assertEq(pool.totalBorrowShares(), 0);
        assertEq(pool.totalBorrowAssets(), 0);
        assertEq(pool.totalBadDebtRealized(), 0);
        assertEq(token.balanceOf(wallet), 1_000e6 + bound - executionDebt);
    }

    function test_tooLateFullRepaymentRevertsAtomicBatchAndPreservesLoan() public {
        RepaymentWallet batch = new RepaymentWallet();
        pool.borrow(1, 1_000e6, address(batch));
        uint256 quotedDebt = pool.loanDebt(1);
        uint256 yearBps = 10_000 * 365 days;
        uint256 denominator = yearBps - pool.MAX_RATE_CAP_BPS() * 300;
        uint256 bound = (quotedDebt * yearBps + denominator - 1) / denominator;
        token.mint(address(batch), bound);
        pool.setRateParams(1_000_000, 8500, 1_000_000, 1_000_000);
        vm.warp(block.timestamp + 601);
        uint256 executionDebt = pool.loanDebt(1);
        assertGt(executionDebt, bound);
        uint256 poolBalance = token.balanceOf(address(pool));
        uint256 walletBalance = token.balanceOf(address(batch));
        uint256 shares = pool.loanShares(1);

        vm.expectRevert(AmplifiLendingPool.InsufficientRepayment.selector);
        batch.payFull(pool, token, 1, bound);

        assertEq(token.balanceOf(address(pool)), poolBalance);
        assertEq(token.balanceOf(address(batch)), walletBalance);
        assertEq(pool.loanShares(1), shares);
        assertEq(pool.loanDebt(1), executionDebt);
        assertEq(pool.totalBadDebtRealized(), 0);

        batch.pay(pool, token, 1, bound, bound);
        assertGt(pool.loanDebt(1), 0);
        assertLt(pool.loanDebt(1), executionDebt);
    }

    function test_borrowerCannotSelfAuthorizeLossOrZeroRepay() public {
        wallet = vm.addr(SIGNER_KEY);
        pool.borrow(1, 100e6, wallet);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signature(1, 0, 100e6, 1, deadline, SIGNER_KEY);
        vm.startPrank(wallet);
        pool.beginRepay(1);
        vm.expectRevert(AmplifiLendingPool.ZeroAmount.selector);
        pool.repay(1, 0);
        vm.expectRevert(AmplifiLendingPool.InvalidSettlementPermit.selector);
        pool.settleLoss(1, 0, 100e6, 1, deadline, sig);
        vm.stopPrank();
        assertEq(pool.totalBadDebtRealized(), 0);
    }

    function test_lossPermitBoundExpiryReplayAndWrongSigner() public {
        pool.borrow(1, 100e6, wallet);
        uint256 deadline = block.timestamp + 300;
        bytes memory wrong = _signature(1, 0, 100e6, 1, deadline, 0x4567);
        bytes memory capped = _signature(1, 0, 99e6, 1, deadline, SIGNER_KEY);
        bytes memory valid = _signature(1, 0, 100e6, 1, deadline, SIGNER_KEY);
        vm.startPrank(wallet);
        pool.beginRepay(1);
        vm.expectRevert(AmplifiLendingPool.InvalidSettlementPermit.selector);
        pool.settleLoss(1, 0, 100e6, 1, deadline, wrong);
        vm.expectRevert(AmplifiLendingPool.WriteOffLimitExceeded.selector);
        pool.settleLoss(1, 0, 99e6, 1, deadline, capped);
        pool.settleLoss(1, 0, 100e6, 1, deadline, valid);
        vm.stopPrank();
        assertTrue(pool.usedSettlementNonces(1));
        assertEq(pool.totalBadDebtRealized(), 100e6);
        pool.borrow(2, 100e6, wallet);
        bytes memory reused = _signature(2, 0, 100e6, 1, deadline, SIGNER_KEY);
        vm.startPrank(wallet);
        pool.beginRepay(2);
        vm.expectRevert(AmplifiLendingPool.InvalidSettlementPermit.selector);
        pool.settleLoss(2, 0, 100e6, 1, deadline, reused);
        vm.stopPrank();
    }

    function test_expiredPermitRejected() public {
        pool.borrow(1, 100e6, wallet);
        uint256 deadline = block.timestamp;
        bytes memory sig = _signature(1, 0, 100e6, 1, deadline, SIGNER_KEY);
        vm.warp(block.timestamp + 1);
        vm.startPrank(wallet);
        pool.beginRepay(1);
        vm.expectRevert(AmplifiLendingPool.InvalidSettlementPermit.selector);
        pool.settleLoss(1, 0, 100e6, 1, deadline, sig);
        vm.stopPrank();
    }

    function test_lossSettlementPreservesEarlierPartialFeeButChargesNoNewFee() public {
        pool.setProtocolFee(1000);
        pool.borrow(1, 100e6, wallet);
        vm.warp(block.timestamp + 365 days);
        _pay(1, 1e6);
        uint256 fee = pool.protocolFeesAccrued();
        assertGt(fee, 0);
        uint256 cap = pool.loanDebt(1);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signature(1, 1e6, cap, 1, deadline, SIGNER_KEY);
        vm.startPrank(wallet);
        pool.beginRepay(1);
        token.transfer(address(pool), 1e6);
        pool.settleLoss(1, 1e6, cap, 1, deadline, sig);
        vm.stopPrank();
        assertEq(pool.protocolFeesAccrued(), fee);
        assertEq(pool.loanDebt(1), 0);
        assertGt(pool.totalBadDebtRealized(), 0);
    }

    function test_ownerWriteOffDoesNotInventRecoveryAndLoanIdCannotBeReused() public {
        pool.borrow(1, 100e6, wallet);
        uint256 cash = token.balanceOf(address(pool));
        vm.prank(wallet);
        vm.expectRevert();
        pool.writeOff(1, 100e6);
        vm.expectRevert(AmplifiLendingPool.WriteOffLimitExceeded.selector);
        pool.writeOff(1, 99e6);
        pool.writeOff(1, 100e6);
        assertEq(token.balanceOf(address(pool)), cash);
        assertEq(pool.totalBadDebtRealized(), 100e6);
        vm.expectRevert(AmplifiLendingPool.LoanAlreadyExists.selector);
        pool.borrow(1, 100e6, wallet);
    }

    function test_borrowPauseLeavesRepaymentAndRedemptionAvailable() public {
        pool.borrow(1, 100e6, wallet);
        pool.setBorrowPaused(true);
        vm.expectRevert(AmplifiLendingPool.BorrowPaused.selector);
        pool.borrow(2, 100e6, wallet);
        _pay(1, 100e6);
        pool.withdrawAssets(100e6);
        pool.setBorrowPaused(false);
        pool.borrow(2, 100e6, wallet);
    }

    function testFuzz_partialPaymentConservation(uint64 principalA, uint64 principalB, uint32 elapsed, uint16 fraction)
        public
    {
        uint256 a = bound(uint256(principalA), 100, 100_000e6);
        uint256 b = bound(uint256(principalB), 100, 100_000e6);
        pool.borrow(1, a, wallet);
        vm.warp(block.timestamp + bound(uint256(elapsed), 1, 365 days));
        pool.borrow(2, b, other);
        uint256 sibling = pool.loanDebt(2);
        uint256 debt = pool.loanDebt(1);
        uint256 amount = debt * bound(uint256(fraction), 1000, 9000) / 10000;
        uint256 beforeAssets = pool.totalAssets();
        uint256 paid = _pay(1, amount);
        assertEq(pool.loanDebt(2), sibling);
        assertGe(pool.loanDebt(1), pool.loanPrincipal(1));
        assertGe(pool.loanDebt(2), pool.loanPrincipal(2));
        assertApproxEqAbs(pool.loanDebt(1), debt - paid, 1);
        assertApproxEqAbs(pool.totalAssets(), beforeAssets, 1);
        _pay(1, pool.loanDebt(1));
        _pay(2, pool.loanDebt(2));
        assertEq(pool.totalBorrowAssets(), 0);
        assertEq(pool.totalBorrowShares(), 0);
    }
}

contract RepaymentCheckpointTransactionTest is Test {
    AmplifiLendingPool pool;
    MockUSDC token;

    function setUp() public {
        token = new MockUSDC();
        pool = new AmplifiLendingPool(address(token), address(this), address(this), 0, 8500, 0, 0, new address[](0));
        pool.setBorrowPaused(false);
        token.mint(address(this), 100e6);
        token.approve(address(pool), 100e6);
        pool.deposit(100e6);
        pool.borrow(1, 50e6, address(this));
        pool.beginRepay(1);
    }

    function test_checkpointCannotSurviveTransactionBoundary() public {
        token.transfer(address(pool), 50e6);
        vm.expectRevert(AmplifiLendingPool.RepaymentNotStarted.selector);
        pool.repay(1, 50e6);
    }
}
