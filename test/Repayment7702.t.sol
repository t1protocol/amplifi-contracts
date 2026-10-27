// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AmplifiLendingPool} from "../src/AmplifiLendingPool.sol";
import {MockUSDC} from "./AmplifiLendingPool.t.sol";

struct DelegatedCall {
    address target;
    bytes data;
}

contract SelfBatchRepayment7702 {
    error OnlySelf();

    function executeBatch(DelegatedCall[] calldata calls) external {
        if (msg.sender != address(this)) revert OnlySelf();
        for (uint256 i; i < calls.length; ++i) {
            (bool success, bytes memory result) = calls[i].target.call(calls[i].data);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(result, 32), mload(result))
                }
            }
        }
    }
}

contract Repayment7702Test is Test {
    uint256 constant BORROWER_KEY = 0xB07702;
    uint256 constant SETTLEMENT_KEY = 0x517702;
    address borrower;
    SelfBatchRepayment7702 implementation;
    AmplifiLendingPool pool;
    MockUSDC token;

    function setUp() public {
        // Change execution rules only; production bytecode remains compiled for Cancun.
        vm.setEvmVersion("prague");
        borrower = vm.addr(BORROWER_KEY);
        assertEq(borrower.code.length, 0);
        token = new MockUSDC();
        pool = new AmplifiLendingPool(
            address(token), address(this), address(this), 1000, 8500, 1000, 1000, new address[](0)
        );
        pool.setBorrowPaused(false);
        pool.setSettlementSigner(vm.addr(SETTLEMENT_KEY));
        token.mint(address(this), 10_000e6);
        token.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);
        pool.borrow(1, 1_000e6, borrower);

        implementation = new SelfBatchRepayment7702();
        vm.signAndAttachDelegation(address(implementation), BORROWER_KEY);
        vm.prank(borrower, borrower);
        SelfBatchRepayment7702(borrower).executeBatch(new DelegatedCall[](0));
        assertEq(borrower.code, abi.encodePacked(hex"ef0100", address(implementation)));
        assertEq(pool.loanWallet(1), borrower, "borrower identity survives delegation");
    }

    function test_delegatedEoaPartialRepaymentUsesItsOwnBalanceWithoutApproval() public {
        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 1 days);
        uint256 debt = pool.loanDebt(1);
        uint256 cash = token.balanceOf(address(pool));
        _execute(_payment(1, 200e6, 200e6, false));
        assertEq(token.balanceOf(borrower), 800e6);
        assertEq(token.balanceOf(address(pool)), cash + 200e6);
        assertApproxEqAbs(pool.loanDebt(1), debt - 200e6, 1);
        assertGt(pool.loanPrincipal(1), 800e6);
        assertEq(token.allowance(borrower, address(pool)), 0);
        assertEq(token.balanceOf(address(implementation)), 0);
    }

    function test_delegatedEoaFullRepaymentRefundsExcessToEoa() public {
        vm.roll(block.number + 200);
        vm.warp(block.timestamp + 3 days);
        uint256 debt = pool.loanDebt(1);
        token.mint(borrower, debt + 10e6 - token.balanceOf(borrower));
        _execute(_payment(1, debt + 10e6, debt + 10e6, true));
        assertEq(pool.loanDebt(1), 0);
        assertEq(pool.totalBorrowShares(), 0);
        assertEq(token.balanceOf(borrower), 10e6);
        assertEq(token.balanceOf(address(implementation)), 0);
    }

    function test_failedDelegatedBatchRollsBackTransferAndCheckpoint() public {
        uint256 cash = token.balanceOf(address(pool));
        DelegatedCall[] memory calls = _payment(1, 200e6, 201e6, false);
        vm.prank(borrower, borrower);
        vm.expectRevert(AmplifiLendingPool.RepaymentAmountMismatch.selector);
        SelfBatchRepayment7702(borrower).executeBatch(calls);
        assertEq(token.balanceOf(borrower), 1_000e6);
        assertEq(token.balanceOf(address(pool)), cash);
        assertEq(pool.loanDebt(1), 1_000e6);
        assertEq(borrower.code, abi.encodePacked(hex"ef0100", address(implementation)));
        _execute(_payment(1, 200e6, 200e6, false));
        assertEq(pool.loanDebt(1), 800e6);
    }

    function test_strangerCannotExecuteDelegatedEoaBatch() public {
        DelegatedCall[] memory calls = _payment(1, 200e6, 200e6, false);
        vm.expectRevert(SelfBatchRepayment7702.OnlySelf.selector);
        SelfBatchRepayment7702(borrower).executeBatch(calls);
        assertEq(token.balanceOf(borrower), 1_000e6);
        assertEq(pool.loanDebt(1), 1_000e6);
    }

    function test_delegatedEoaSignedLossAndInvalidPermitRollback() public {
        uint256 deadline = block.timestamp + 300;
        bytes memory signature = _lossSignature(400e6, 600e6, deadline);
        DelegatedCall[] memory calls = _payment(1, 400e6, 400e6, false);
        calls[2].data = abi.encodeCall(pool.settleLoss, (1, 400e6, 599e6, 1, deadline, signature));
        vm.prank(borrower, borrower);
        vm.expectRevert(AmplifiLendingPool.InvalidSettlementPermit.selector);
        SelfBatchRepayment7702(borrower).executeBatch(calls);
        assertEq(token.balanceOf(borrower), 1_000e6);
        assertEq(pool.loanDebt(1), 1_000e6);
        assertFalse(pool.usedSettlementNonces(1));

        calls[2].data = abi.encodeCall(pool.settleLoss, (1, 400e6, 600e6, 1, deadline, signature));
        _execute(calls);
        assertEq(token.balanceOf(borrower), 600e6);
        assertEq(pool.loanDebt(1), 0);
        assertEq(pool.totalBadDebtRealized(), 600e6);
        assertTrue(pool.usedSettlementNonces(1));
        assertEq(token.allowance(borrower, address(pool)), 0);
    }

    function test_twoLoansCanRepaySequentiallyInOneDelegatedBatch() public {
        pool.borrow(2, 500e6, borrower);
        DelegatedCall[] memory first = _payment(1, 200e6, 200e6, false);
        DelegatedCall[] memory second = _payment(2, 100e6, 100e6, false);
        DelegatedCall[] memory calls = new DelegatedCall[](6);
        for (uint256 i; i < 3; ++i) {
            calls[i] = first[i];
            calls[i + 3] = second[i];
        }
        _execute(calls);
        assertEq(pool.loanDebt(1), 800e6);
        assertEq(pool.loanDebt(2), 400e6);
        assertEq(token.balanceOf(borrower), 1_200e6);
    }

    function _payment(uint256 id, uint256 transferred, uint256 claimed, bool full)
        internal
        view
        returns (DelegatedCall[] memory calls)
    {
        calls = new DelegatedCall[](3);
        calls[0] = DelegatedCall(address(pool), abi.encodeCall(pool.beginRepay, (id)));
        calls[1] = DelegatedCall(address(token), abi.encodeCall(token.transfer, (address(pool), transferred)));
        calls[2] = DelegatedCall(
            address(pool),
            full ? abi.encodeCall(pool.repayFull, (id, claimed)) : abi.encodeCall(pool.repay, (id, claimed))
        );
    }

    function _execute(DelegatedCall[] memory calls) internal {
        vm.prank(borrower, borrower);
        SelfBatchRepayment7702(borrower).executeBatch(calls);
    }

    function _lossSignature(uint256 amount, uint256 maxWriteOff, uint256 deadline)
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
        bytes32 contents =
            keccak256(abi.encode(pool.LOSS_SETTLEMENT_TYPEHASH(), 1, borrower, amount, maxWriteOff, 1, deadline));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(SETTLEMENT_KEY, keccak256(abi.encodePacked("\x19\x01", domain, contents)));
        return abi.encodePacked(r, s, v);
    }
}
