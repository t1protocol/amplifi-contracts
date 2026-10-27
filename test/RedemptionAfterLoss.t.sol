// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {AmplifiLendingPool, PoolStatus} from "../src/AmplifiLendingPool.sol";
import {MockUSDC} from "./AmplifiLendingPool.t.sol";

contract RedemptionAfterLossTest is Test {
    AmplifiLendingPool pool;
    MockUSDC token;
    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address delegate = makeAddr("delegate");
    address receiver = makeAddr("receiver");

    function setUp() public {
        token = new MockUSDC();
        pool = new AmplifiLendingPool(
            address(token), address(this), address(this), 1000, 8500, 1000, 1000, new address[](0)
        );
        pool.setBorrowPaused(false);
        _deposit(lender, 1000e6);
    }

    function _deposit(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.startPrank(account);
        token.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();
    }

    function _lose(uint256 id, uint256 amount) internal {
        pool.borrow(id, amount, borrower);
        pool.writeOff(id, amount);
    }

    function _earnFeesThenLose() internal returns (uint256 fees) {
        pool.setProtocolFee(1000);
        pool.borrow(1, 500e6, borrower);
        vm.warp(block.timestamp + 365 days);
        uint256 debt = pool.loanDebt(1);
        token.mint(borrower, debt);
        vm.startPrank(borrower);
        pool.beginRepay(1);
        token.transfer(address(pool), debt);
        pool.repayFull(1, debt);
        vm.stopPrank();
        fees = pool.protocolFeesAccrued();
        assertGt(fees, 0);
        _lose(2, 200e6);
    }

    function test_fullShareWithdrawalAfterLossLeavesProtocolFeesCollectible() public {
        uint256 fees = _earnFeesThenLose();
        uint256 shares = pool.balanceOf(lender);
        uint256 lpCash = token.balanceOf(address(pool)) - fees;
        assertEq(pool.previewRedeem(shares), lpCash);
        assertEq(pool.convertToAssets(shares), lpCash);
        assertEq(pool.maxRedeem(lender), shares);
        assertEq(pool.maxWithdraw(lender), lpCash);
        pool.setBorrowPaused(true);
        pool.setPoolStatus(PoolStatus.WindingDown);
        pool.setPoolStatus(PoolStatus.Closed);
        vm.prank(lender);
        assertEq(pool.withdraw(shares), lpCash);
        assertEq(token.balanceOf(lender), lpCash);
        assertEq(pool.totalSupply(), 0);
        assertEq(token.balanceOf(address(pool)), fees);
        assertEq(pool.protocolFeesAccrued(), fees);
        pool.collectProtocolFees(receiver, fees);
        assertEq(token.balanceOf(receiver), fees);
        assertEq(token.balanceOf(address(pool)), 0);
    }

    function test_delegatedRedeemAfterLossRequiresAllowanceAndPaysChosenReceiver() public {
        uint256 fees = _earnFeesThenLose();
        uint256 shares = pool.balanceOf(lender);
        uint256 cash = token.balanceOf(address(pool));
        vm.prank(delegate);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, delegate, 0, shares));
        pool.redeem(shares, receiver, lender);
        assertEq(pool.balanceOf(lender), shares);
        assertEq(token.balanceOf(address(pool)), cash);
        vm.prank(lender);
        pool.approve(delegate, shares);
        vm.prank(delegate);
        assertEq(pool.redeem(shares, receiver, lender), cash - fees);
        assertEq(token.balanceOf(receiver), cash - fees);
        assertEq(pool.allowance(lender, delegate), 0);
        assertEq(pool.totalSupply(), 0);
        assertEq(token.balanceOf(address(pool)), fees);
    }

    function test_partialWithdrawalAfterLossUsesNormalQuoteBeforeFinalExit() public {
        _lose(1, 500e6);
        uint256 supply = pool.totalSupply();
        uint256 cash = token.balanceOf(address(pool));
        uint256 partialShares = supply / 2;
        uint256 expected = partialShares * (cash + 1e3) / (supply + 1e3);
        vm.prank(lender);
        assertEq(pool.withdraw(partialShares), expected);
        vm.prank(lender);
        assertEq(pool.redeem(supply - partialShares, lender, lender), cash - expected);
        assertEq(token.balanceOf(lender), cash);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(pool.totalSupply(), 0);
    }

    function test_lastHolderCannotRedeemIlliquidLoansEvenAfterAnotherLoanIsLost() public {
        pool.borrow(1, 500e6, borrower);
        _lose(2, 200e6);
        uint256 shares = pool.balanceOf(lender);
        uint256 quote = shares * (pool.totalAssets() + 1e3) / (pool.totalSupply() + 1e3);
        assertEq(pool.previewRedeem(shares), quote);
        assertGt(quote, pool.availableLiquidity());
        assertLt(pool.maxRedeem(lender), shares);
        vm.startPrank(lender);
        vm.expectRevert(AmplifiLendingPool.InsufficientLiquidity.selector);
        pool.withdraw(shares);
        vm.expectRevert(AmplifiLendingPool.InsufficientLiquidity.selector);
        pool.redeem(shares, lender, lender);
        vm.stopPrank();
        assertEq(pool.balanceOf(lender), shares);
        assertEq(pool.loanDebt(1), 500e6);
    }

    function test_donationDoesNotReleaseVirtualShareReserveToFinalHolder() public {
        token.mint(address(pool), 1000e6);
        uint256 shares = pool.balanceOf(lender);
        uint256 cash = token.balanceOf(address(pool));
        uint256 quote = shares * (cash + 1e3) / (shares + 1e3);
        assertLt(quote, cash);
        vm.prank(lender);
        assertEq(pool.redeem(shares, lender, lender), quote);
        assertEq(token.balanceOf(address(pool)), cash - quote);
    }

    function test_assetWithdrawalOverloadsKeepTheirRoundingAndFeeReserve() public {
        uint256 fees = _earnFeesThenLose();
        uint256 lpCash = pool.availableLiquidity();
        uint256 first = lpCash / 3;
        uint256 firstShares = pool.previewWithdraw(first);
        vm.prank(lender);
        assertEq(pool.withdraw(first, receiver, lender), firstShares);
        uint256 restShares = pool.previewWithdraw(lpCash - first);
        vm.prank(lender);
        assertEq(pool.withdrawAssets(lpCash - first), restShares);
        assertEq(token.balanceOf(receiver) + token.balanceOf(lender), lpCash);
        assertEq(token.balanceOf(address(pool)), fees);
        assertEq(pool.protocolFeesAccrued(), fees);
        assertEq(pool.previewRedeem(pool.balanceOf(lender)), 0);
        assertEq(pool.maxRedeem(lender), 0);
        assertEq(pool.maxWithdraw(lender), 0);
    }

    function test_emptyLossPoolReportsZeroUntilAssetsReturn() public {
        _lose(1, 1000e6);
        uint256 shares = pool.balanceOf(lender);
        assertEq(pool.previewRedeem(shares), 0);
        assertEq(pool.maxRedeem(lender), 0);
        vm.prank(lender);
        vm.expectRevert(AmplifiLendingPool.ZeroAmount.selector);
        pool.withdraw(shares);
        token.mint(address(pool), 1);
        assertEq(pool.maxRedeem(lender), shares);
        vm.prank(lender);
        assertEq(pool.withdraw(shares), 1);
        assertEq(pool.totalSupply(), 0);
        assertEq(token.balanceOf(address(pool)), 0);
        _deposit(receiver, 1000e6);
        assertEq(pool.balanceOf(receiver), 1000e6);
        vm.prank(receiver);
        assertEq(pool.withdraw(1000e6), 1000e6);
    }

    function testFuzz_finalLossExitNeverSpendsFees(uint256 rawLoss, uint256 donation, bool redeem) public {
        uint256 fees = _earnFeesThenLose();
        uint256 loss = bound(rawLoss, 1, pool.availableLiquidity());
        _lose(3, loss);
        donation = bound(donation, 0, 500e6);
        token.mint(address(pool), donation);
        uint256 cash = token.balanceOf(address(pool));
        uint256 shares = pool.balanceOf(lender);
        uint256 quote = pool.previewRedeem(shares);
        assertLe(quote, cash - fees);
        if (quote == 0) return;
        vm.prank(lender);
        uint256 paid = redeem ? pool.redeem(shares, receiver, lender) : pool.withdraw(shares);
        assertEq(paid, quote);
        assertEq(pool.totalSupply(), 0);
        assertEq(token.balanceOf(receiver) + token.balanceOf(lender), paid);
        assertEq(token.balanceOf(address(pool)) + paid, cash);
        assertGe(token.balanceOf(address(pool)), fees);
        pool.collectProtocolFees(address(this), fees);
        assertEq(token.balanceOf(address(this)), fees);
    }
}
